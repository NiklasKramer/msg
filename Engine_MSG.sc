
Engine_MSG : CroneEngine {
	classvar nvoices = 8;

	var pg;
	var reverb;
	var delay;
	var <buffers;
	var <voices;
	var reverbBus;
	var delayBus;
	var saturation;
	var saturationBus;
	var filterbank;
	var filterbankBus;
	var <phases;
	var <levels;

	var <seek_tasks;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}



	// disk read
	readBuf { arg i, path;
		("Reading buffer " ++ i ++ " from " ++ path).postln;
		if(buffers[i].notNil, {
			if (File.exists(path), {
				var temp = Buffer.read(context.server, path, 0, 1, {
				  // get a temporary buffer to get the number of channels. In its callback, get two channels.
				  // This is because grainbuf is single channel.
				  if (temp.numChannels == 1, {
				    var newbuf = Buffer.readChannel(context.server, path, 0, -1, [0], {
  					  voices[i].set(\buf1, newbuf, \buf2, newbuf);
	  				  buffers[i].do(_.free);
					    buffers[i] = [newbuf];
				    });
				  });
				  if (temp.numChannels == 2, {
				    var newbuf = [nil, nil];
				    var c = CondVar();
				    var remaining = 2;
				    2.do { |j|
				      newbuf[j] = Buffer.readChannel(context.server, path, 0, -1, [j], {
				        remaining = remaining - 1;
				        c.signalOne;
				      });
				    };
				    fork {
				      while { remaining > 0 } { c.wait() };
				      // at this point the buffer should be loaded.
				      voices[i].set(\buf1, newbuf[0], \buf2, newbuf[1]);
				      buffers[i].do(_.free);
				      buffers[i] = newbuf;
				    };
				  });
				});
			});
		});
	}

	setBufferLength { arg i, length;
		if(buffers[i].notNil, {
			buffers[i].do(_.free);
			buffers[i] = [Buffer.alloc(context.server, context.server.sampleRate * length)];
			voices[i].set(\buf1, buffers[i][0], \buf2, buffers[i][0]);
		});
	}

	saveBuffer { arg i, path;
		if(buffers[i].notNil, {
			// Extract the directory from the path
			// Create the directory if it doesn't exist
			// Save the buffer to the specified path
			buffers[i][0].write(path, "wav");
		});
	}

	freeBuffer { arg i;
		if(buffers[i].notNil, {
			buffers[i].do(_.free);
			buffers[i] = nil;
		});
	}

	setBufferForVoice { arg voiceIndex, bufferIndex;
    if (voices[voiceIndex].notNil and: { buffers[bufferIndex].notNil }) {
        voices[voiceIndex].set(\buf1, buffers[bufferIndex][0], \buf2, buffers[bufferIndex][0]);
    } {
        "Invalid voice or buffer index".postln;
    }
}


	alloc {
		~tf =  Env([-0.7, 0, 0.7], [1,1], [8,-8]).asSignal(1025);
		~tf = ~tf + (
			Signal.sineFill(
				1025,
				(0!3) ++ [0,0,1,1,0,1].scramble,
				{rrand(0,2pi)}!9
			)/10;
		);
		~tf = ~tf.normalize;
		~tfBuf = Buffer.loadCollection(context.server, ~tf.asWavetableNoWrap);
		buffers = Array.fill(nvoices, { arg i;
			[Buffer.alloc(
				context.server,
				context.server.sampleRate * 1,
			)];
		});

		SynthDef(\synth, {
			arg out=0, in=0, phase_out=0, level_out=0, 
				saturation_out=0, saturation_level=0, 
				delay_out=0, delay_level=0, 
				reverb_out=0, reverb_level=0, 
				filterbank_out=0, filterbank_level=0, 
				pan=0, buf1, buf2,
				gate=0, pos=0, speed=1, jitter=0, fade=0.5, direction=1,
				size=0.1, density=20, finetune=1, semitones=0, octaves=0, spread=0,wobble=0, 
				gain=1, envscale=1, attack=1, sustain=1, release=1, record=0,
				freeze=0, t_reset_pos=0, filterControl=0.5, useBufRd=1, mute=1, fadeTime=0.1,
				clicky=0, speed_lag_time=0.1, tremolo_rate=0, tremolo_depth=0, bitDepth=24, sampleRate=44100, reductionMix=0; 

			var grain_trig, buf_dur, pan_sig, jitter_sig, buf_pos, pos_sig, sig, smooth_mute, pitch, selected_buf_pos;
			var aOrB, crossfade, reset_pos_a, reset_pos_b, updated_semitones, semitones_in_hz, clicky_sig, gran_sig;
			var wobble_lfo_freq, wobble_lfo_depth, wobble_lfo, wobble_rate;
			var t_buf_pos_a, t_buf_pos_b, buf_rd_left_a, buf_rd_right_a, buf_rd_left_b, buf_rd_right_b;
			var env, level, cutoffFreqLPF, cutoffFreqHPF, dryAndHighPass, filtered, stereo_sig, tremoloLFO, signal, record_pos, reduced;

			speed = Lag.kr(speed, speed_lag_time );

			// Initialize triggers and random signals
			grain_trig = Impulse.kr(density);
			buf_dur = BufDur.kr(buf1);
			pan_sig = TRand.kr(trig: grain_trig, lo: spread.neg, hi: spread);
			jitter_sig = TRand.kr(trig: grain_trig, lo: buf_dur.reciprocal.neg * jitter, hi: buf_dur.reciprocal * jitter);
			buf_pos = Phasor.ar(trig: t_reset_pos, rate: buf_dur.reciprocal / SampleRate.ir * speed * direction, resetPos: pos);
			
			pos_sig = Wrap.ar(Select.kr(freeze, [buf_pos, pos]));

			// Apply fade time to mute control
			smooth_mute = Lag.kr(mute, fadeTime);

			// Buffer reading control
			aOrB = ToggleFF.kr(t_reset_pos);
			crossfade = K2A.ar(aOrB);

			semitones = Lag.kr(semitones, speed_lag_time);
			octaves = Lag.kr(octaves, speed_lag_time);

			reset_pos_a = Latch.kr(pos * BufFrames.kr(buf1), aOrB);
			reset_pos_b = Latch.kr(pos * BufFrames.kr(buf1), 1 - aOrB);
			updated_semitones = octaves * 12 + semitones;
			semitones_in_hz = (2 ** (updated_semitones / 12.0));

			wobble_lfo_freq = LinLin.kr(wobble, 0, 1, 0.8, 25); 
			wobble_lfo_depth = LinLin.kr(wobble, 0, 1, 0.0, 0.1);
			wobble_lfo = SinOsc.kr(wobble_lfo_freq, 0, wobble_lfo_depth, 1);
			
			wobble_rate = BufRateScale.kr(bufnum: buf1) * speed * semitones_in_hz * wobble_lfo * direction;

			t_buf_pos_a = Phasor.ar(
				trig: aOrB,
				rate: wobble_rate,
				start: 0,
				end: BufFrames.kr(bufnum: buf1),
				resetPos: reset_pos_a
			);

			t_buf_pos_b = Phasor.ar(
				trig: 1 - aOrB,
				rate: wobble_rate,
				start: 0,
				end: BufFrames.kr(bufnum: buf1),
				resetPos: reset_pos_b
			);

			pitch = finetune * semitones_in_hz;

			// Recording
			signal = SoundIn.ar([0, 1]);
			
			selected_buf_pos = Select.ar(aOrB, [t_buf_pos_b, t_buf_pos_a]);
			record_pos = Select.ar(useBufRd, [pos_sig, selected_buf_pos]);

			BufWr.ar(signal[0], buf1*record, record_pos);
			BufWr.ar(signal[1], buf2*record, record_pos);

			gran_sig = Mix.ar(GrainBuf.ar(2, grain_trig, size, [buf1, buf2], pitch, (pos_sig + jitter_sig), 2, ([-1, 1] + pan_sig).clip(-1, 1))) / 2;


			// Signal generation with clicky control
			sig = Select.ar(useBufRd, [
				    gran_sig,

				{
					buf_rd_left_a = BufRd.ar(1, buf1, t_buf_pos_a, loop: 1) ;
					buf_rd_right_a = BufRd.ar(1, buf2, t_buf_pos_a, loop: 1) ;

					buf_rd_left_b = BufRd.ar(1, buf1, t_buf_pos_b, loop: 1) ;
					buf_rd_right_b = BufRd.ar(1, buf2, t_buf_pos_b, loop: 1) ;

					
					[
						(crossfade * buf_rd_left_a) + ((1 - crossfade) * buf_rd_left_b),
						(crossfade * buf_rd_right_a) + ((1 - crossfade) * buf_rd_right_b)
					]
					
				}
			]);

			clicky_sig = Select.ar(useBufRd, [
				    gran_sig,
					[
						BufRd.ar(1, buf1, record_pos, loop: 1),
						BufRd.ar(1, buf2, record_pos, loop: 1)
					]]);

			sig = Select.ar(clicky, [sig, clicky_sig]);

			
			// Bitcrusher
			reduced = Decimator.ar(sig, rate: sampleRate, bits: bitDepth);
			sig = XFade2.ar(sig, reduced, (reductionMix * 2) - 1);

			// Apply tremolo
			tremoloLFO = SinOsc.kr(Lag.kr(tremolo_rate, 0.1), 0, tremolo_depth, 1);
			sig = sig * tremoloLFO;

			// Envelope generation
			env = EnvGen.kr(Env.asr(attack, sustain, release), gate: gate, timeScale: envscale);
			level = env;

			// Filter controls
			cutoffFreqLPF = LinExp.kr(filterControl.clip(0, 0.5) * 2, 0, 1, 20, 15000);
			cutoffFreqHPF = LinExp.kr((filterControl - 0.5).clip(0, 0.5) * 2, 0, 1, 20, 15000);

			dryAndHighPass = Select.ar(filterControl > 0.51, [
				sig,
				HPF.ar(sig, cutoffFreqHPF)
			]);

			filtered = Select.ar(filterControl > 0.5, [
				LPF.ar(sig, cutoffFreqLPF),
				dryAndHighPass,
			]);

			// Pan and balance
			stereo_sig = Balance2.ar(filtered[0], filtered[1], pan);

			// Output signals
			Out.ar(out, stereo_sig * level * gain * smooth_mute);
			Out.ar(saturation_out, stereo_sig * level * saturation_level * smooth_mute);
			Out.ar(delay_out, stereo_sig * level * delay_level * smooth_mute);
			Out.ar(reverb_out, stereo_sig * level * reverb_level * smooth_mute);
			Out.ar(filterbank_out, stereo_sig * level * filterbank_level * smooth_mute);
			
			// Control signals
			Out.kr(phase_out, (Select.kr(useBufRd, [pos_sig, selected_buf_pos / BufFrames.kr(buf1)]) * smooth_mute));
			Out.kr(level_out, level * smooth_mute);
		}).add;

		///////////////////////////////////////////

		SynthDef(\saturator, { |in=0, out=0, srate=48000, sdepth=32, crossover=1400, distAmount=15, lowbias=0.04, highbias=0.12, hissAmount=0.0, cutoff=11500, outVolume=1|
			var input = In.ar(in, 2);  // Read 2 channels from the input
			var crossAmount = 50;

			// Process each channel independently
			var processChannel = { |channel|
				var decimated = Decimator.ar(channel, srate, sdepth);
				
				var lpf = LPF.ar(
					decimated, 
					crossover + crossAmount, 
					1 
				) * lowbias;

				var hpf = HPF.ar(
					decimated,
					crossover - crossAmount,
					1
				) * highbias;

				var beforeHiss = Mix.new([
					Mix.new([lpf, hpf]),
					HPF.ar(Mix.new([PinkNoise.ar(0.001), Dust.ar(5, 0.002)]), 2000, hissAmount)
				]);

				var compressed = Compander.ar(beforeHiss, decimated,
					thresh: 0.2,
					slopeBelow: 1,
					slopeAbove: 0.3,
					clampTime: 0.001,
					relaxTime: 0.1
				);
				var shaped = Shaper.ar(~tfBuf, compressed * distAmount);

				var afterHiss = HPF.ar(Mix.new([PinkNoise.ar(1), Dust.ar(5, 1)]), 2000, 1);

				var duckedHiss = Compander.ar(afterHiss, decimated,
					thresh: 0.4,
					slopeBelow: 1,
					slopeAbove: 0.2,
					clampTime: 0.01,
					relaxTime: 0.1
				) * 0.5 * hissAmount;

				var morehiss = Mix.new([
					duckedHiss, 
					Mix.new([lpf * (1 / lowbias) * (distAmount / 10), shaped])
				]);

				var limited = Limiter.ar(Mix.new([
					decimated * 0.5,
					morehiss
				]), 0.9, 0.01);

				MoogFF.ar(
					limited,
					cutoff,
					1
				)
			};

			// Apply processing to both channels
			var processed = input.collect(processChannel);

			// set the output volume
			processed = processed * outVolume;
			// Output the processed signal
			Out.ar(out, processed * outVolume);
		}).add;

		// Delay SynthDef
		SynthDef(\td_22, {|out=0, in=32, delay=0.2, time=10, hpf=330, lpf=8200, w_rate=0.667, w_depth=0.00027, rotate=0.0, mix=0.2, i_max_del=8|
			var sig, mod, del, fbs, fb;
			
			sig = In.ar(in, 2);
			fb = exp(log(0.001) * (delay / time));

			mod = LFPar.kr(w_rate, mul: w_depth);
			fbs = LocalIn.ar(2);
			fbs = Rotate2.ar(fbs[0], fbs[1], rotate).softclip;
			del = DelayL.ar(Limiter.ar(Mix([fbs * fb, sig]), 0.99, 0.01), i_max_del, delay + mod);
			del = LPF.ar(HPF.ar(del, hpf), lpf);
			LocalOut.ar(del);
			Out.ar(out, 1 - mix * sig + (mix * del));
		}).add;

		// Reverb SynthDef
		SynthDef(\scverb_12, {|out=0, in=22, mix=1, time=5, lpf=8200, hpf=20, srate=0|
			var apj, sig, mods, delays, dts, fbs, fb, filts, filteredSig;
			sig = In.ar(in).dup;
			dts = Select.kr(srate, [
				[0.056077097505669, 0.062743764172336, 0.072947845804989, 0.080657596371882, 0.08859410430839, 0.093582766439909, 0.04859410430839, 0.043832199546485],
				[0.056104166666667, 0.062729166666667, 0.073145833333333, 0.080770833333333, 0.088604166666667, 0.093604166666667, 0.048604166666667, 0.043729166666667],
				[0.056052083333333, 0.062802083333333, 0.072927083333333, 0.080635416666667, 0.088552083333333, 0.093739583333333, 0.048572916666667, 0.043760416666667]
			]);
			// Integrating calcFeedback logic
			fb = exp(log(0.001) * (0.089 / time));

			mods = LFNoise2.kr([3.1, 3.5, 1.110, 3.973, 2.341, 1.897, 0.891, 3.221],
				[0.0010, 0.0011, 0.0017, 0.0006, 0.0010, 0.0011, 0.0017, 0.0006]
			);
			fbs = LocalIn.ar(8);
			apj = 0.25 * Mix.ar(fbs);
			delays = DelayC.ar(sig - fbs + apj, 1, dts + mods);
			filts = LPF.ar(delays * fb, lpf);
			// Adding High-Pass Filter
			filteredSig = HPF.ar(filts, hpf);
			LocalOut.ar(DelayC.ar(filteredSig, ControlRate.ir.reciprocal, ControlRate.ir.reciprocal));
			Out.ar(out,
				1 - mix * sig + (mix * 0.35 * [Mix.ar([filteredSig[0], filteredSig[2], filteredSig[4], filteredSig[6]]), Mix.ar([filteredSig[1], filteredSig[3], filteredSig[5], filteredSig[7]])])
			);
		}).add;

		SynthDef(\filterbank, {
			arg out = 0, in = 0, amp = 1, gate = 1, spread = 1, q = 0.05, modRate = 0.2, depth = 0.5, qModRate = 0.1, qModDepth = 0.01, panModRate = 0.4, panModDepth = 1, wet = 1, 
			reverb_out = 0, reverb_level=0, delay_out = 0, delay_level =0, saturation_out = 0, saturation_level = 0;
			var freqs, source, drySignal, bands, modulations, ampMod, panMod, qMod, adjustedVolume, wetSignal, out_signal;

			// Define the center frequencies of each band
			freqs = [50, 125, 185, 270, 385, 540, 765, 1100, 1550, 2150, 3000, 4250, 6000, 8500, 12000, 17000];

			// Input source from the bus (stereo)
			source = In.ar(in, 2);
			
			// Dry signal (unprocessed)
			drySignal = source;
			
			// Generate smooth random modulations for each band's volume
			modulations = freqs.collect { LFNoise1.kr(modRate).range(1 - depth / 2, 1 + depth / 2).lag(10) };

			// Generate amplitude modulations for each band
			ampMod = freqs.collect { LFNoise1.kr(modRate * 0.7).range(0.1, 2).lag(5) };

			// Generate panning modulations for each band
			panMod = freqs.collect { LFNoise1.kr(panModRate).range(spread * panModDepth * -1, spread * panModDepth).lag(0.1) };

			// Generate q modulations
			qMod = LFNoise1.kr(qModRate).range(1 - qModDepth / 2, 1 + qModDepth / 2) * q;

			// Adjust volume based on q
			adjustedVolume = q.reciprocal * 0.5; // Example adjustment factor, you can tweak this

			// Apply a bandpass filter to each band for the left and right channels
			bands = source.collect { |chan|
				freqs.collect { |freq, i|
					var modAmp, panPos;
					modAmp = ampMod[i];
					panPos = panMod[i];
					Pan2.ar(BPF.ar(chan, freq, qMod) * modulations[i] * modAmp, panPos)
				}.sum
			};

			// Apply amplitude envelope
			wetSignal = bands * EnvGen.kr(Env.adsr, gate, doneAction: 2) * amp * adjustedVolume;
			out_signal = XFade2.ar(drySignal, wetSignal, wet * 2 - 1);

			// Mix dry and wet signals
			Out.ar(out, out_signal);
			Out.ar(reverb_out, out_signal * reverb_level);
			Out.ar(delay_out, out_signal * delay_level);
			Out.ar(saturation_out, out_signal * saturation_level);

		}).add;

		
		
	
		context.server.sync;

	

		// Allocate and initialize buses
        reverbBus = Bus.audio(context.server, 2); // Mix bus for all synth outputs
		delayBus = Bus.audio(context.server, 2); // Delay bus
        saturationBus = Bus.audio(context.server, 2); // Saturation bus
		filterbankBus = Bus.audio(context.server, 2); // Filterbank bus

        // Initialize reverb and saturation synths
		reverb = Synth.new(\scverb_12, [\in, reverbBus, \out, context.out_b.index], target: context.xg);
		delay = Synth.new(\td_22, [\in, delayBus, \out, context.out_b.index], target: context.xg);
        saturation = Synth.new(\saturator, [\in, saturationBus, \out, context.out_b.index], target: context.xg);
		filterbank = Synth.new(\filterbank, [\in, filterbankBus, \out, context.out_b.index, \reverb_out, reverbBus, \delay_out, delayBus, \saturation_out, saturationBus], target: context.xg);


		phases = Array.fill(nvoices, { arg i; Bus.control(context.server); });
		levels = Array.fill(nvoices, { arg i; Bus.control(context.server); });

		pg = ParGroup.head(context.xg);

		voices = Array.fill(nvoices, { arg i;
			Synth.new(\synth, [
				\out, context.out_b.index,
				\phase_out, phases[i].index,
				\level_out, levels[i].index,
				
				\saturation_out, saturationBus.index,
				\reverb_out, reverbBus.index,
				\delay_out, delayBus.index,
				\filterbank_out, filterbankBus.index,
				

				\buf1, buffers[i][0],
				\buf2, buffers[i][0]
			], target: pg);
		});

		context.server.sync;

		// REVERB
		this.addCommand("reverb_time", "f", { arg msg; reverb.set(\time, msg[1]); });
		this.addCommand("reverb_mix", "f", { arg msg; reverb.set(\mix, msg[1]); });
		this.addCommand("reverb_lpf", "f", { arg msg; reverb.set(\lpf, msg[1]); });
		this.addCommand("reverb_hpf", "f", { arg msg; reverb.set(\hpf, msg[1]); });
		this.addCommand("reverb_srate", "f", { arg msg; reverb.set(\srate, msg[1]); });

		// DELAY
		this.addCommand("delay_delay", "f", { arg msg; delay.set(\delay, msg[1]); });
		this.addCommand("delay_time", "f", { arg msg; delay.set(\time, msg[1]); });
		this.addCommand("delay_mix", "f", { arg msg; delay.set(\mix, msg[1]); });
		this.addCommand("delay_lpf", "f", { arg msg; delay.set(\lpf, msg[1]); });
		this.addCommand("delay_hpf", "f", { arg msg; delay.set(\hpf, msg[1]); });
		this.addCommand("delay_w_rate", "f", { arg msg; delay.set(\w_rate, msg[1]); });
		this.addCommand("delay_w_depth", "f", { arg msg; delay.set(\w_depth, msg[1]); });
		this.addCommand("delay_rotate", "f", { arg msg; delay.set(\rotate, msg[1]); });
		this.addCommand("delay_max_del", "f", { arg msg; delay.set(\i_max_del, msg[1]); });

		// SATURATION
		this.addCommand("saturation_depth", "f", { arg msg; saturation.set(\sdepth, msg[1]); });
		this.addCommand("saturation_rate", "f", { arg msg; saturation.set(\srate, msg[1]); });
		this.addCommand("saturation_crossover", "f", { arg msg; saturation.set(\crossover, msg[1]); });
		this.addCommand("saturation_dist", "f", { arg msg; saturation.set(\distAmount, msg[1]); });
		this.addCommand("saturation_lowbias", "f", { arg msg; saturation.set(\lowbias, msg[1]); });
		this.addCommand("saturation_highbias", "f", { arg msg; saturation.set(\highbias, msg[1]); });
		this.addCommand("saturation_hiss", "f", { arg msg; saturation.set(\hissAmount, msg[1]); });
		this.addCommand("saturation_cutoff", "f", { arg msg; saturation.set(\cutoff, msg[1]); });
		this.addCommand("saturation_volume", "f", { arg msg; saturation.set(\outVolume, msg[1]); });

		// FILTERBANK
		this.addCommand("filterbank_amp", "f", { arg msg; filterbank.set(\amp, msg[1]); });
		
		// FILTERBANK
		this.addCommand("filterbank_gate", "f", { arg msg; filterbank.set(\gate, msg[1]); });
		this.addCommand("filterbank_spread", "f", { arg msg; filterbank.set(\spread, msg[1]); });
		this.addCommand("filterbank_q", "f", { arg msg; filterbank.set(\q, msg[1]); });
		this.addCommand("filterbank_modRate", "f", { arg msg; filterbank.set(\modRate, msg[1]); });
		this.addCommand("filterbank_depth", "f", { arg msg; filterbank.set(\depth, msg[1]); });
		this.addCommand("filterbank_qModRate", "f", { arg msg; filterbank.set(\qModRate, msg[1]); });
		this.addCommand("filterbank_qModDepth", "f", { arg msg; filterbank.set(\qModDepth, msg[1]); });
		this.addCommand("filterbank_panModRate", "f", { arg msg; filterbank.set(\panModRate, msg[1]); });
		this.addCommand("filterbank_panModDepth", "f", { arg msg; filterbank.set(\panModDepth, msg[1]); });
		this.addCommand("filterbank_wet", "f", { arg msg; filterbank.set(\wet, msg[1]); });
		this.addCommand("filterbank_reverb_level", "f", { arg msg; filterbank.set(\reverb_level, msg[1]); });
		this.addCommand("filterbank_delay_level", "f", { arg msg; filterbank.set(\delay_level, msg[1]); });
		this.addCommand("filterbank_saturation_level", "f", { arg msg; filterbank.set(\saturation_level, msg[1]); });


		
		this.addCommand("read", "is", { arg msg;
			this.readBuf(msg[1] - 1, msg[2]);
		});

		this.addCommand("seek", "if", { arg msg;
			var voice = msg[1] - 1;
			var lvl, pos;
			var seek_rate = 1 / 750;

			seek_tasks[voice].stop;

			// TODO: async get
			lvl = levels[voice].getSynchronous();

			if (false, { // disable seeking until fully implemented
				var step;
				var target_pos;

				// TODO: async get
				pos = phases[voice].getSynchronous();
				voices[voice].set(\freeze, 1);

				target_pos = msg[2];
				step = (target_pos - pos) * seek_rate;

				seek_tasks[voice] = Routine {
					while({ abs(target_pos - pos) > abs(step) }, {
						pos = pos + step;
						voices[voice].set(\pos, pos);
						seek_rate.wait;
					});

					voices[voice].set(\pos, target_pos);
					voices[voice].set(\freeze, 0);
					voices[voice].set(\t_reset_pos, 1);
				};

				seek_tasks[voice].play();
			}, {
				pos = msg[2];

				voices[voice].set(\pos, pos);
				voices[voice].set(\t_reset_pos, 1);
				voices[voice].set(\freeze, 0);
			});
		});

		this.addCommand("buffer_length", "if", { arg msg;
			this.setBufferLength(msg[1] - 1, msg[2]);
		});

		this.addCommand("free_buffer", "i", { arg msg;
			this.freeBuffer(msg[1] - 1);
		});

		this.addCommand("save_buffer", "is", { arg msg;
			this.saveBuffer(msg[1] - 1, msg[2]);
		});

		this.addCommand("gate", "ii", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\gate, msg[2]);
		});

		this.addCommand("record", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\record, msg[2]);
		});

		this.addCommand("set_buffer_for_voice", "ii", { arg msg;
			this.setBufferForVoice(msg[1] - 1, msg[2] - 1);  
		});

		this.addCommand("speed", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\speed, msg[2]);
		});

		this.addCommand("direction", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\direction, msg[2]);
		});


		this.addCommand("jitter", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\jitter, msg[2]);
		});

		this.addCommand("size", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\size, msg[2]);
		});

		this.addCommand("density", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\density, msg[2]);
		});

		this.addCommand("finetune", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\finetune, msg[2]);
		});

		this.addCommand("semitones", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\semitones, msg[2]);
		});

		this.addCommand("octaves", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\octaves, msg[2]);
		});

		this.addCommand("filter", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\filterControl, msg[2]);
		});

		this.addCommand("spread", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\spread, msg[2]);
		});

		this.addCommand("volume", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\gain, msg[2]);
		});

		this.addCommand("mute", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\mute, msg[2]);
		});

		this.addCommand("pan", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\pan, msg[2]);
		});

		this.addCommand("fade", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\fade, msg[2]);
		});

		this.addCommand("lagtime", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\speed_lag_time, msg[2]);
		});

		this.addCommand("envscale", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\envscale, msg[2]);
		});

		this.addCommand("attack", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\attack, msg[2]);
		});

		this.addCommand("sustain", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\sustain, msg[2]);
		});

		this.addCommand("release", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\release, msg[2]);
		});

		this.addCommand("tremoloRate", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\tremolo_rate, msg[2]);
		});

		this.addCommand("tremoloDepth", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\tremolo_depth, msg[2]);
		});

		this.addCommand("bitDepth", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\bitDepth, msg[2]);
		});

		this.addCommand("sampleRate", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\sampleRate, msg[2]);
		});

		this.addCommand("reductionMix", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\reductionMix, msg[2]);
		});

		this.addCommand("wobble", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\wobble, msg[2]);
		});

		this.addCommand("saturation", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\saturation_level, msg[2]);
		});

		this.addCommand("delay", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\delay_level, msg[2]);
		});

		this.addCommand("reverb", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\reverb_level, msg[2]);
		});

		this.addCommand("filterbank", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\filterbank_level, msg[2]);
		});

		this.addCommand("useBufRd", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\useBufRd, msg[2]);
		});

		this.addCommand("clicky", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\clicky, msg[2]);
		});
	
		
	
		nvoices.do({ arg i;
			this.addPoll(("phase_" ++ (i+1)).asSymbol, {
				var val = phases[i].getSynchronous;
				val
			});

			this.addPoll(("level_" ++ (i+1)).asSymbol, {
				var val = levels[i].getSynchronous;
				val
			});
		});

		seek_tasks = Array.fill(nvoices, { arg i;
			Routine {}
		});
	}

	free {
		voices.do({ arg voice; voice.free; });
		phases.do({ arg bus; bus.free; });
		levels.do({ arg bus; bus.free; });
		buffers.do({ arg b; b.do(_.free); });
		reverb.free;
		reverbBus.free;
		delay.free;
		delayBus.free;
		saturation.free;
		saturationBus.free;
		filterbank.free;
		filterbankBus.free;
	}
}