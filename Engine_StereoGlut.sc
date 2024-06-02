
Engine_MSG : CroneEngine {
	classvar nvoices = 7;

	var pg;
	var reverb;
	var delay;
	var <buffers;
	var <voices;
	var reverbBus;
	var delayBus;
	var saturation;
	var saturationBus;
	var <phases;
	var <levels;

	var <seek_tasks;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}



	// disk read
	readBuf { arg i, path;
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
			arg out=0, phase_out=0, level_out=0, saturation_out=0, saturation_level=0, delay_out=0, delay_level=0, reverb_out=0, reverb_level=0, buf1, buf2,
			gate=0, pos=0, speed=1, jitter=0,
			size=0.1, density=20, pitch=1, spread=0, gain=1, envscale=1,attack=1, sustain=1, release=1,
			freeze=0, t_reset_pos=0, filterControl=0.5; // Added filterControl parameter

			var grain_trig, jitter_sig, buf_dur, pan_sig, buf_pos, pos_sig, sig;
			var env, level, filtered, cutoffFreqLPF, cutoffFreqHPF, dryAndHighPass;

			grain_trig = Impulse.kr(density);
			buf_dur = BufDur.kr(buf1);
			pan_sig = TRand.kr(trig: grain_trig, lo: spread.neg, hi: spread);
			jitter_sig = TRand.kr(trig: grain_trig, lo: buf_dur.reciprocal.neg * jitter, hi: buf_dur.reciprocal * jitter);
			buf_pos = Phasor.kr(trig: t_reset_pos, rate: buf_dur.reciprocal / ControlRate.ir * speed, resetPos: pos);
			pos_sig = Wrap.kr(Select.kr(freeze, [buf_pos, pos]));

			sig = Mix.ar(GrainBuf.ar(2, grain_trig, size, [buf1, buf2], pitch, pos_sig + jitter_sig, 2, ([-1, 1] + pan_sig).clip(-1, 1)))/2;
			env = EnvGen.kr(Env.asr(attack, sustain, release), gate: gate, timeScale: envscale);

			level = env;

			// Filter logic adapted from vintageSamplerEmu
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

			Out.ar(out, filtered * level * gain);
			Out.ar(saturation_out, filtered * level * saturation_level);
			Out.ar(delay_out, filtered * level * delay_level);
			Out.ar(reverb_out, filtered * level * reverb_level);
			Out.kr(phase_out, pos_sig);
			// Ignore gain for level out to maintain original logic
			Out.kr(level_out, level);
		}).add;

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

		
		
		

	
		context.server.sync;

	

		// Allocate and initialize buses
        reverbBus = Bus.audio(context.server, 2); // Mix bus for all synth outputs
		delayBus = Bus.audio(context.server, 2); // Delay bus
        saturationBus = Bus.audio(context.server, 2); // Saturation bus

        // Initialize reverb and saturation synths
		reverb = Synth.new(\scverb_12, [\in, reverbBus, \out, context.out_b.index], target: context.xg);
		delay = Synth.new(\td_22, [\in, delayBus, \out, context.out_b.index], target: context.xg);
        saturation = Synth.new(\saturator, [\in, saturationBus, \out, context.out_b.index], target: context.xg);


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

		this.addCommand("gate", "ii", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\gate, msg[2]);
		});

		this.addCommand("speed", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\speed, msg[2]);
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

		this.addCommand("pitch", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\pitch, msg[2]);
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
	}
}
