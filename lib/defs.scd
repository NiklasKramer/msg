SynthDef(\simpleBufLoop, {
|out=0, buf, pos=0, rate=1, amp=1, t_reset=0, playhead_out, gate=1, reverse=0, sendABus=0, sendALevel=0, sendBBus=0, sendBLevel=0, hpf=0, lpf=1|
var sig, sig2, phase, phase2, frames, rateHz, env;
var startA, startB, endA, endB, aOrB, crossfade;

    frames = BufFrames.kr(buf);
    rateHz = BufRateScale.kr(buf) * Lag.kr(rate, 0.1) * (reverse == 1).if({ -1 }, { 1 });

    aOrB = ToggleFF.kr(t_reset);
    startA = Latch.kr(pos, aOrB);
    startB = Latch.kr(pos, 1 - aOrB);
    crossfade = Lag.ar(K2A.ar(aOrB), 0.01);

    endA = 1.0;
    endB = 1.0;

    phase = Phasor.ar(
    	trig: aOrB,
    	rate: rateHz,
    	start: startA,
    	end: endA * frames,
    	resetPos: startA * frames
    );

    sig = BufRd.ar(2, buf, phase, loop: 1);

    phase2 = Phasor.ar(
    	trig: 1 - aOrB,
    	rate: rateHz,
    	start: startB,
    	end: endB * frames,
    	resetPos: startB * frames
    );

    sig2 = BufRd.ar(2, buf, phase2, loop: 1);

    sig = (crossfade * sig) + ((1 - crossfade) * sig2);
    sig = LPF.ar(sig, Lag.kr(lpf.linexp(0, 1, 100, 20000), 0.2));
    sig = HPF.ar(sig, Lag.kr(hpf.linexp(0, 1, 20, 10000), 0.2));

    env = EnvGen.kr(Env.adsr(2, 0.1, 1, 1), gate, doneAction: 2);
    sig = sig * env * Lag.kr(amp,2);
    Out.ar(out, sig);
    Out.kr(playhead_out, Select.kr(aOrB, [phase2, phase]) / frames);
    Out.ar(sendABus, sig * Lag.kr(sendALevel, 0.1));
    Out.ar(sendBBus, sig * Lag.kr(sendBLevel, 0.1));

}).add;

SynthDef(\sendFreeverb, { |in, out = 0, mix = 1, room = 1, damp = 0|
var sig = In.ar(in, 2);
sig = FreeVerb.ar(sig, mix, room, damp);
Out.ar(out, sig);
}).add;

SynthDef(\masterLimiter, {
arg in = 0, out = 0;
var sig;
sig = In.ar(in, 2);
sig = Limiter.ar(sig, 0.99, 0.01);
Out.ar(out, sig);
}).add;

// Simple tape delay SynthDef
SynthDef(\sendTapeDelay, {
|in=0, out=0, fb=0.6, fc=5000, dlytime=0.125, wet=0.5, pan=0.0|
var local, sig, delayed, phi, phR, phP, freq, tdbh;

    tdbh = 0.125;
    local = LocalBuf(SampleRate.ir * 3, 1);

    phi = (2 * tdbh) / BufDur.ir(local);
    freq = 1.0 / BufDur.ir(local);
    freq = (freq * tdbh) / VarLag.kr(dlytime, 2, warp:\linear);

    phR = LFSaw.ar(freq, phi, 0.5, 0.5) * BufFrames.kr(local);
    phP = LFSaw.ar(freq, 0.0, 0.5, 0.5) * BufFrames.kr(local);

    sig = Mix.ar(In.ar(in, 2));
    delayed = BufRd.ar(1, local, phP, loop: 1);
    delayed = delayed.tanh;

    BufWr.ar(LPF.ar(sig + delayed, fc) * fb, local, phR, loop: 1);
    pan = LFNoise1.ar(5);
    Out.ar(out, Pan2.ar(delayed * wet, pan));

}).add;
