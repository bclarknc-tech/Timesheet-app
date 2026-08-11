# Voice-reactive lighting for Jarvis.
#
# Paints the voice line's live state onto the keyboard and RAM through
# OpenRGB's SDK on 6742, and onto the Razer mouse through Razer's own Chroma
# SDK on 54235.
#
# TWO output paths, deliberately: OpenRGB cannot drive Brian's Basilisk V3 Pro
# 35K Phantom Green at all (writes succeed, nothing lights - see chroma.ps1's
# header for the proof), so the mouse goes through Chroma instead. The Chroma
# half is FAILURE-ISOLATED: if the SDK is missing, the services are stopped, or
# Synapse is closed, the mouse is simply skipped and the keyboard and RAM carry
# on exactly as before. The mouse must never be able to darken the board.
#
# Reads the voice signal bus FILES directly (~/voice-line/.voice_state and
# .voice_waveform) rather than the visualizer's HTTP /state endpoint. Two
# reasons, both learned the hard way:
#   1. System.Net.Http.HttpClient does not exist in Windows PowerShell 5.1
#      without explicitly loading the assembly. The first version of this
#      script used it, New-Object failed NON-terminatingly, $http stayed
#      null, and every frame's poll threw into an empty catch - so the whole
#      thing rendered near-black forever with a completely clean log.
#   2. Reading two small files is cheaper than an HTTP round trip per frame,
#      and removes a dependency on the visualizer server being up at all.
#
# Freshness/level maths are copied deliberately from voice-visualizer's
# server.py read_bus_state() so both surfaces agree on what "speaking" means.
#
# Stop it by creating the file named in $StopFile, or kill the process.

param(
    [string]$VoiceDir    = 'C:\Users\bclar\voice-line',
    [string]$DeviceMatch = 'Vulcan',
    [int]   $Fps         = 30,
    # Measured, not guessed: the heartbeat log showed Brian's voice line peaks
    # around 0.37 of full scale in normal speech, so without gain the bloom
    # never reached the outer third of the board. 2.6 maps a normal speaking
    # peak to full width; it clamps at 1.0 so shouting just saturates.
    [double]$Gain        = 2.6,
    [string]$StopFile    = 'C:\Users\bclar\openrgb\STOP',
    [string]$LogFile     = 'C:\Users\bclar\openrgb\voice-lights.log',
    # The mouse goes over HTTP, one request per frame - at the full 30 fps that
    # is 30 round trips a second competing with the OpenRGB sends inside a 33 ms
    # frame budget. 10 fps is smooth to the eye on a 12-LED device and leaves
    # the budget to the hardware that actually has resolution to show.
    [int]   $MouseFps    = 10,
    # 'pulse' = the whole mouse takes the bloom's PEAK colour, so it flashes at
    # full brightness with the voice.
    # 'bloom' = the bloom is mapped down the mouse's rows, matching how the
    #           keyboard and RAM travel.
    #
    # Defaults to 'pulse' on Brian's call, 2026-08-01: 'bloom' was built first
    # and he found it dim and inert (*"can you make the mouse brighter maybe? or
    # more active?"*). The cause is real and worth keeping - Get-StripFrame
    # scales bloom width PROPORTIONALLY to strip length, which is correct for
    # 104 keys and 64 RAM LEDs but leaves a 9-row mouse with a band only two or
    # three rows wide and everything else dark. Proportional scaling stops
    # making sense at very short strips.
    [ValidateSet('pulse','bloom')]
    [string]$MouseStyle  = 'pulse',
    # --- the four surfaces added 2026-08-01 ---
    # Thermaltake radiator fans and the motherboard's ARGB header both sit on
    # ADDRESSABLE channels, which OpenRGB reports as 0 LEDs because channel
    # length cannot be auto-detected. These counts are DECLARED on every
    # startup (see Get-DeviceSet) - the size does not survive an OpenRGB
    # restart, which is why both looked dead until 2026-08-01.
    #
    # Over-declaring is harmless; under-declaring leaves real LEDs dark. These
    # are deliberate over-guesses until the true counts are measured by eye.
    [int]   $TtLedsPerChannel   = 30,   # Riing Plus 12/fan, Riing Trio 30, Quad 54
    [int]   $AuraLedsPerChannel = 60,
    # Fan look, settled live with Brian watching the rig on 2026-08-01.
    #
    # 'pulse' = the whole ring takes the bloom's PEAK colour. This is the
    # default and the correct one for his mounting: the radiator fans face
    # DOWNWARD, so he only ever sees the thin edge of the ring, never its face.
    # A gradient travelling around the ring is invisible to him - whatever arc
    # he can see just reads as one flat colour, which is why reversing the
    # direction changed nothing. Same conclusion as the mouse.
    #
    # 'bloom' maps the gradient around the ring; only useful if the fans are
    # ever remounted facing the viewer.
    # 'trio' = treat the three radiator fans as a THREE-ELEMENT strip: the
    # centre fan gets the bloom's red core, the outer two get its white edges,
    # brightness driven by voice. Brian's own idea, 2026-08-01 ("maybe the
    # center fan is red and the other ones will turn white when you speak"),
    # and it falls straight out of the locked red-centre/white-edge design -
    # a 3-LED render of that bloom IS white, red, white.
    #
    # This is the default because a per-LED gradient is invisible on his rig
    # (fans face downward, only the edge of each ring is visible) but three
    # whole fans differing from each other reads clearly from across the room.
    [ValidateSet('trio','pulse','bloom')]
    [string]$FanStyle    = 'trio',
    # Physical fan -> Riing channel, MEASURED by eye 2026-08-01 by lighting each
    # channel a different colour and having Brian read them back. 1-based, as
    # printed on the controller. Do not assume channel order matches physical
    # order - here it does not.
    #   channel 1 = CENTRE fan, channel 2 = RIGHT fan, channel 3 = LEFT fan
    #   channels 4 and 5 = a separate Thermaltake piece on the motherboard
    [int]   $FanCentreChannel = 1,
    [int]   $FanRightChannel  = 2,
    [int]   $FanLeftChannel   = 3,
    # ⚠ Per-channel colour correction, FANS ONLY. Brian, 2026-08-01: "the blue
    # almost looks like a light green and the white looks like a white yellow."
    #
    # Diagnosis, from evidence already collected rather than a new test: during
    # the channel-mapping pass, pure red, pure green and pure blue each rendered
    # correctly on these fans. Only MIXES are wrong. That means the blue emitter
    # is simply weaker than red and green, so anything containing blue skews
    # away from it - white picks up a yellow cast, and the idle blue (which
    # deliberately carries some green) reads as light green.
    #
    # Correction is therefore to pull RED and GREEN back, never to push blue up:
    # blue is already at full scale in both cases and has no headroom. The cost
    # is real and worth knowing - a neutral white on these fans is dimmer than
    # full output, because it is capped by the weakest emitter.
    [double]$FanRedGain   = 1.00,
    [double]$FanGreenGain = 1.00,
    [double]$FanBlueGain  = 1.00,
    # ⭐ The fix that actually made fan colour correct. Brian, 2026-08-01: "more
    # blue than that and more white than that, like an LED white and an LED
    # blue. It can do it, I've seen it do it."
    #
    # He was right and the earlier diagnosis was wrong. The emitters are fine.
    # The problem is that these fans were being driven at the bloom's raw
    # amplitude - around 40% at idle - and LED colour skews badly at low output
    # because the three emitters do not dim at the same rate. That is why blue
    # went green and white went yellow, and why trimming channel gains only
    # traded one wrong colour for another.
    #
    # Fix: NORMALISE each fan colour so its brightest channel hits full scale -
    # which preserves hue and saturation exactly while giving full LED punch -
    # then apply brightness separately with a high floor, so the fans still
    # breathe with the voice but never drop into the range where colour falls
    # apart. Floor first, then span; 0.55/0.45 means they range 55%-100%.
    # Brightness range for the fans, floor first then span (0.18/0.82 = 18%-100%).
    #
    # Started at 0.55/0.45 to stop colour skewing at low output, then opened
    # right up once the pure palette above landed - Brian, 2026-08-01: "the red
    # and white need to have a more noticeable difference from dim to bright so
    # you can see your voice better." **The high floor is only needed for MIXED
    # colours.** A dimmed pure red is still red and a dimmed pure blue is still
    # blue, so with flat primaries the floor buys nothing and costs all the
    # dynamics. If the palette is ever made non-primary again, raise it back.
    [double]$FanFloor = 0.08,
    [double]$FanSpan  = 0.92,
    # Exponent on the brightness input before floor/span. >1 pushes the middle
    # of the range DOWN while leaving the peaks at full, so quiet speech falls
    # away sharply instead of hovering near bright. This is what actually reads
    # as "drastic" - widening the range alone still left the mid-levels sitting
    # too high. Brian asked for it a little more drastic on 2026-08-01 after the
    # range was already opened to 18-100%.
    [double]$FanGamma = 1.8,
    # The IDLE-only fan curve - see the note where it is applied. Floor 0.78 with
    # a small span keeps the pure blue near maximum output while leaving a shallow
    # breathe, so it reads as bright rather than static. Raising the floor is the
    # ONLY correct way to make it brighter; adding green/red would just wash it
    # out to pale blue, which is specifically what Brian did not want.
    [double]$FanIdleFloor = 0.78,
    [double]$FanIdleSpan  = 0.22,
    [double]$FanIdleGamma = 1.0,
    # The KNIGHT RIDER scanner on the three fans while thinking. Brian asked for
    # the left-to-right amber wave first, saw it, then replaced it: "do it like
    # Knight Rider - from left to right, just red, back and forth, and as bright
    # as you can, when you're thinking only." The amber-wave version is gone
    # rather than left behind a flag; this replaced it.
    #
    # ⚠ There is NO width/falloff parameter here, on purpose. A distance falloff
    # was built first and Brian could not read the movement - with only three
    # positions a spatial gradient always leaves two fans permanently part-lit.
    # The head STEPS one fan at a time; the trail comes from $FanScanDecay
    # instead. Do not reintroduce a spatial falloff; it was tried and rejected.
    #
    # Unlit fans go fully DARK, not dim. Brian: "you need to turn off the fan
    # light so it doesn't even need to be lit up." Note the fan curve's own 0.08
    # floor will lift any non-zero value back to a visible ~20, which is why the
    # scanner zeroes small values outright rather than relying on this.
    # Bounces per phase cycle. $phase comes round in ~4.2 s, so 4.0 puts a full
    # there-and-back at ~1.05 s - four steps of ~0.26 s. Raised from 2.5 on
    # Brian's call ("need to make it faster").
    # 4.0 -> 8.0 -> 16.0, each doubling on Brian's call. He approved 8.0 by eye
    # ("that looks pretty good") then asked for double again.
    #
    # 16.0 is a full there-and-back in ~0.26 s - four steps of ~0.065 s. This is
    # ONLY renderable because $ExtrasFps went to 30 at the same time; at 15 it
    # would skip steps and look erratic rather than fast. The two numbers are a
    # pair - do not raise this one on its own.
    [double]$FanScanSpeed = 16.0,
    # Fraction of its brightness a fan keeps each extras frame (15/sec) once the
    # head has left it. 0.55 fades a fan out over roughly a quarter second, so
    # the tail is still visibly behind the head at this speed without smearing
    # into a constant glow. Lower = crisper and shorter; higher = longer streak.
    [double]$FanScanDecay = 0.55,
    # Same saturate-then-dim treatment for the ADDRESSABLE STRIP and the GPU,
    # but harder than the fans. Brian, 2026-08-01: "make it more drastic on the
    # addressable strip and on the GPU." The strip was still running the
    # keyboard's gentle dynamics and the GPU was only on the fans' curve.
    # Reverses the strip's red-to-white ramp. Which physical end is LED 0 cannot
    # be detected - if red lands at the top instead of the bottom, flip this.
    [bool]  $AuraFlip   = $false,
    # How fast the strip's red-to-white ramp completes, as a multiple of the
    # declared channel length. 1.0 = white only at the very last LED; 2.0 = fully
    # white halfway along.
    #
    # This exists because the physical strip is almost certainly SHORTER than the
    # 60 LEDs declared per channel (its real length cannot be queried). With a
    # 1.0 ramp across 60 declared LEDs, a 30-LED strip only ever reaches half
    # saturation - which is exactly what Brian saw: pink at the top instead of
    # white. Raising this compresses the ramp into the part that physically
    # exists. Measuring the true length would let this go back to 1.0.
    [double]$AuraRampGain = 3.5,
    # Strip brightness. Opened up hard on 2026-08-01 - Brian asked for it "really
    # bright" and noticeably breathing on speech. The 0.03/2.4 curve it started
    # on was tuned for drama and left the whole strip too dark to read.
    # Strip brightness, taken to the top on Brian's instruction 2026-08-01:
    # "make the addressable strip as bright as you could make it." Floor 0.70
    # means it never drops below 70% and still lifts to full on speech, so it
    # reads as bright with a visible breathe rather than a dim pulse.
    # 'gate' = hard-switched: FULL red while speaking, completely OFF otherwise.
    # No gradient, no breathe, no cross-fade. Brian's explicit call 2026-08-01:
    # "I want it to just go full on red, full off, full on red, full off."
    # Everything smooth we tried on this strip read as mush; a hard binary
    # switch is the only thing that reads clearly on it.
    # 'gradient' keeps the earlier red-to-white ramp.
    [ValidateSet('fade','gate','gradient')]
    [string]$AuraStyle  = 'fade',
    # 'fade' = the same syllable-driven red, but its own fast envelope instead
    # of a hard on/off. Brian, 2026-08-01: the binary gate read as "really
    # choppy" at every threshold we tried, and no threshold fixes that - a hard
    # switch can only ever chop. Attack near-instant so syllables punch, decay
    # quick but not instant so it falls toward dark instead of snapping.
    # Values are per extras-frame (15 fps), not per render frame.
    [double]$AuraAttack = 0.85,
    [double]$AuraDecay  = 0.30,
    # ⭐ 2026-08-01: Brian replaced the red-centre/white-edge BLOOM on the
    # keyboard, RAM and mouse with the strip's flat state+syllable effect,
    # explicitly and for good ("I'm gonna change the bloom for good... leave it
    # on the fans though"). The bloom was a locked design he had signed off the
    # night before, so this was surfaced and confirmed before overwriting it.
    # The FANS keep their trio treatment; only these three changed.
    #
    # Same envelope shape as the strip's, but the coefficients are re-derived
    # for 30 fps rather than the extras' 15 fps so the feel actually matches -
    # reusing 0.85/0.30 here would have been twice as fast.
    [double]$FlatAttack = 0.62,
    [double]$FlatDecay  = 0.16,
    # RAM-only brightness range. Brian, 2026-08-01, wanted the sticks swinging
    # further from dim to bright than the flat colour gives on its own. Applied
    # through the same saturate-then-dim helper the fans use, so the hue stays
    # exact and only the brightness range widens.
    [double]$RamFloor = 0.08,
    [double]$RamSpan  = 0.92,
    [double]$RamGamma = 1.7,
    # Voice level (post-gain) at which the strip snaps on.
    # Tuned by ear with Brian watching live, 2026-08-01: 0.22 -> 0.30 ("pretty
    # good") -> 0.45 (too far, "really choppy") -> 0.28. Higher drops out more
    # decisively between syllables but starts chopping up continuous speech;
    # lower reads smoother but blurs the gaps. 0.28 is the settled value.
    [double]$AuraGateLevel = 0.28,
    [bool]  $AuraInvert = $true,
    [double]$ExtraFloor = 0.15,
    [double]$ExtraSpan  = 0.85,
    [double]$ExtraGamma = 1.2,
    # ⚠ The GPU gets its OWN, much gentler curve - do not fold it back in with
    # the strip. Brian, 2026-08-01: the card did speaking but "doesn't do the
    # yellow when you're thinking" and wouldn't visibly return to idle.
    #
    # Verified by recording the voice bus at 5 Hz through a real turn: all four
    # states fire cleanly (listening 9s, thinking 13s, then speaking). The state
    # machine was never the problem. The card had been given the STRIP's curve -
    # 3% floor, 2.4 gamma - which is correct for 60 LEDs where you read shape,
    # and wrong for one small logo LED where there is no shape to read, only
    # colour and brightness. Everything quieter than a loud syllable was crushed
    # to invisible.
    #
    # A single-LED surface needs a HIGH floor so every state reads solid, with
    # the voice riding on top of it.
    # ⚠ UNRESOLVED as of 2026-08-01: at idle the card renders MAGENTA even
    # though the frame sent to it is arithmetically pure blue with zero in the
    # red channel. Red is arriving from somewhere the code does not put it.
    # It rendered pure blue correctly during the first colour-cycle test, which
    # was driven flat out - so the working hypothesis is that this logo LED
    # misbehaves at partial brightness. The high floor below is a TEST of that
    # theory, not a known fix. If magenta persists at 0.55, the theory is wrong
    # and the next step is driving the card with fixed full-brightness colours
    # per state and no brightness modulation at all.
    # ---------------------------------------------------------------------
    # SUPERSEDED 2026-08-01: the block of commentary directly above describes
    # the card as UNRESOLVED/magenta and justifies a squashed 0.55 floor. Both
    # are obsolete. The magenta was Armoury Crate writing to this same LED, so
    # our colour arrived blended with its own; the high floor was an attempt to
    # overpower that blend. Armoury Crate was stopped and the loop restarted -
    # Brian confirmed "It's blue." With the blend gone the compensation was pure
    # loss of dynamic range, which is why the card looked nearly inert.
    #
    # Now the SAME curve shape as the RAM, because the card now runs the SAME
    # flat state+syllable effect as the keyboard, RAM and mouse. Brian, 2026-08-01:
    # "make the GPU do the same thing."
    #
    # If Armoury Crate is ever started again, DO NOT reach for these numbers -
    # stop it and restart this loop instead. See the vault note.
    # ⚠ GpuGamma is deliberately BELOW 1.0, which is the opposite of every other
    # surface here. Do not "correct" it upward.
    #
    # Measured 2026-08-01 by logging the real bytes leaving for this card through
    # a live turn, after two rounds of reasoning about it were both wrong. The
    # speaking effect was never broken - it was invisible. Brian's voice envelope
    # sits at roughly 0.2-0.5 with peaks near 0.68, and it almost never reaches
    # the top of the range. A gamma above 1 crushes exactly that band: at 1.6 a
    # typical syllable rendered ~60/255 and his loudest only reached 149/255, so
    # a small logo LED read as "dark red", never as flashing. Thinking looked
    # fine by contrast only because its amp is pinned at 1.0 and hit full 255.
    #
    # Below 1.0 the curve EXPANDS the quiet band instead: a typical syllable now
    # lands near 180 and the gaps stay around 35, which is what reads as a flash.
    # The floor drops with it so those gaps stay genuinely dark.
    #
    # If his voice pipeline's levels ever change, re-measure with the GPUDIAG
    # logging rather than adjusting this by eye.
    # FINAL VALUES, 2026-08-01. Brian: "that's perfect except on the low end you
    # need to go a little less bright, so it shows more."
    #
    # The 0.80 gamma that fixed the invisible-speech problem was OVERSHOOTING by
    # the time the rest was tuned: it lifts the quiet band, which is exactly the
    # band the gaps between syllables live in, so the contrast washed out. Now
    # linear with a near-zero floor. A typical syllable drops 79 -> 56 and a
    # quiet moment 51 -> 31, while his loudest barely moves, 190 -> 179. The
    # peaks were already right; only the floor under them needed to come down.
    [double]$GpuFloor = 0.02,
    [double]$GpuSpan  = 1.00,
    [double]$GpuGamma = 1.00,
    # ⚠ The GPU gets its OWN, much SLOWER update rate - it is not part of the
    # extras pacing. Raising this back up will break the effect, not improve it.
    #
    # Proven 2026-08-01 with the loop paused: stepped through full red, full
    # blue, full red and then a dim blue at exactly the idle value, two seconds
    # apart. Brian: "It did exactly what you said it would do." So the hardware
    # is fine, dim values render fine, and the LED is not latching.
    #
    # It simply cannot absorb 15 writes a second. A GPU logo LED sits behind a
    # slow bus, and the writes queue faster than the card drains them. That one
    # fact explains BOTH symptoms that looked unrelated: the syllable flashes
    # smeared into a constant glow, and the card "stayed red" after speech
    # because the backlog of red frames was still playing out into the idle.
    #
    # TUNED BY EYE, 2026-08-01, and the ceiling is LOWER than it looks. 15 was
    # mush. 5 worked - Brian confirmed the flashing and the return to blue. 8 was
    # then tried because he found 5 slightly stepped, and 8 BROKE IT AGAIN: he
    # saw "light blue" through a whole sentence while the log proved red values
    # of 85, 123 and 179 had been sent. That gap between what was sent and what
    # showed is the queue - at 8/sec the backlog grows a couple of frames a
    # second, so over a four-second sentence the red arrived roughly two seconds
    # late, after he had stopped watching for it.
    #
    # ⚠ This card's real ceiling is around 6/sec. Do NOT raise this to smooth the
    # rhythm - that is what broke it. Smooth it with $GpuTail instead.
    [double]$GpuFps   = 5,
    # Fraction of the previous flash carried into the next peak-hold window.
    #
    # At 5 writes a second a pure peak-then-reset makes each syllable a separate
    # block with nothing between - Brian: "your syllables might be a little
    # broken looking." Carrying part of the last value forward gives every flash
    # a short tail, so consecutive writes connect into a rhythm at the SAME slow
    # frame rate. 0 restores the old hard-stepped behaviour; too high and the
    # tail never decays and it smears back into a constant glow.
    [double]$GpuTail  = 0.45,
    # --- ROOM LIGHTING (Govee lamps / ChromaLink). DORMANT unless set. --------
    # Written 2026-08-01 ahead of the hardware arriving. Nothing runs unless one
    # of these is supplied, so adding it could not disturb the working rig.
    #
    # $GoveeIps: one or more lamp addresses. ⚠ "LAN Control" must be switched on
    # per-device in the Govee MOBILE app first - it is OFF by default, and if the
    # toggle is absent that model has no local control at all.
    # $UseChromaLink: route through Razer Chroma instead (Govee desktop app +
    # Synapse must both be running). Kept as a fallback only - it is no longer
    # the "only path to the segments", see below.
    #
    # !! UPDATED 2026-08-02 - THE LAMPS ARE NOW REAL SURFACES, NOT FLAT COLOURS.
    # This block used to push one whole-device colour because the RGBIC segments
    # were believed unreachable over LAN. They are not: the undocumented
    # DreamView/"razer" frame drives them directly. A lamp is now rendered as a
    # $GoveeSegments-pixel strip and gets the same frames the fans and the ARGB
    # strip get - bloom, amber wave, scanner, idle blue. No special cases.
    #
    # $GoveeSegments: 10, MEASURED on Brian's H6022 by walking one lit segment
    #   and having him count the stops. !! Segment 0 is the BOTTOM. !! Too many
    #   segments does NOT error - the extras are silently dropped, so a wrong
    #   count looks like "the top of the lamp is dead".
    # $GoveeFps: 20. MEASURED, not guessed: 32 packets/sec sustained on the H6022
    #   with no visible lag or stutter, watched. 20 leaves real headroom. Govee's
    #   published "one command per 100 ms" applies to the documented API, not to
    #   this stream - but the GPU's lesson still stands, so do not push it to the
    #   measured ceiling.
    [string[]]$GoveeIps = @(),
    [switch]  $UseChromaLink,
    [double]  $GoveeFps = 20,
    [int]     $GoveeSegments = 10,
    # --- LAMP-ONLY PALETTE. Brian, 2026-08-02: "make the blue on the light more
    # blue, the green more green, and make the breathing heavier" - then "make
    # the yellow more yellow, it looks orange."
    #
    # !! LAMP ONLY, ON HIS EXPLICIT INSTRUCTION. He was asked directly whether
    # this was the lamp or the whole rig and said lamp. The shared constants
    # drive six other surfaces he signed off across several tuning sessions -
    # see the numbered design calls in the vault note, several of which are
    # reversals. DO NOT fold these values back into the shared palette.
    #
    # WHY a diffused lamp needs its own numbers at all: the shared colours carry
    # deliberate secondary content (the idle blue has green in it, the listening
    # green has blue in it, thinking is amber = red plus a lot of green). On
    # keycaps and bare LEDs that reads as a rich hue; through frosted plastic the
    # channels mix further and it washes toward pastel - and amber crosses the
    # line into orange. These are the same hues with the secondaries pulled down.
    [double[]]$GoveeIdleRgb   = @(0.00, 0.08, 1.00),   # was 0.10/0.30/0.90
    [double[]]$GoveeListenRgb = @(0.00, 1.00, 0.06),   # was 0.05/1.00/0.30
    # Thinking. Shared is 1.00/0.45/0.02 = amber. Through the diffuser that read
    # plainly orange, and 0.86 green was still orange to him - so this is now
    # textbook yellow, equal red and green. If it EVER still reads orange, the
    # lamp's red channel is simply hotter than its green and the fix is to pull
    # red DOWN (0.85/1.00/0.00), not to push green past full.
    [double[]]$GoveeThinkRgb  = @(1.00, 1.00, 0.00),
    [double[]]$GoveeSpeakRgb  = @(1.00, 0.04, 0.00),   # unchanged in hue, kept here for one place
    # Breathing depth on the lamp. Shared idle is 0.28 + 0.18*breath - a shallow
    # swing. "Heavier" is a deeper one: dimmer at the bottom, brighter at the top.
    [double]  $GoveeBreathFloor = 0.14,
    [double]  $GoveeBreathSpan  = 0.62,
    # --- LIGHT SHOW MODE. Brian, 2026-08-02: "I'd like to see a fucking crazy
    # light show." Runs a fixed choreography across every surface at once and
    # then exits; the caller restarts the normal voice loop afterwards.
    #
    # It lives in THIS file rather than a separate script on purpose: all the
    # device discovery, the RAM slot ordering, the zone resizing, the Chroma
    # session and the per-lamp Govee handling already exist here, and a second
    # copy of 200 lines of that is exactly the kind of duplication that drifts.
    [switch]  $Show,
    # --- MUSIC MODE. Brian, 2026-08-02: "a crazy fucking light show that goes
    # to whatever music I play... it can change per music."
    #
    # ~\musiclights\analyser.py captures the speakers over WASAPI loopback and
    # publishes level / bass / mid / treble / beat here. This loop is a pure
    # CONSUMER of that file, exactly as it is of the voice bus - if the analyser
    # is not running, not installed, or crashes, nothing here changes.
    #
    # !! JARVIS'S OWN TTS COMES OUT OF THE SAME SPEAKERS, so this bus goes hot
    # when he talks. The analyser deliberately does not try to filter that. The
    # decision lives HERE, where the voice state is already known: TTS always
    # wins, music only drives the lights when Jarvis is not speaking.
    [string]  $MusicBus = (Join-Path $env:USERPROFILE 'musiclights\.music_bus'),
    [double]  $MusicFreshSec = 1.5,
    [switch]  $NoMusic,
    # !! RUNTIME OFF SWITCH. If this file exists, music never drives the lights.
    # Brian, 2026-08-02: "I want to make sure I can turn that off. So if I'm
    # just playing a podcast, it's not going crazy."
    #
    # A FILE rather than a parameter on purpose: a parameter would need the
    # render loop restarted, which drops every light for ~15 s just to silence
    # them. Creating or deleting this takes effect on the next frame, and both
    # `Music Lights Toggle.bat` and Jarvis himself write the same flag.
    [string]  $MusicOffFlag = (Join-Path $PSScriptRoot 'MUSIC_OFF'),
    # --- SCREEN MODE. Brian, 2026-08-03: "I play Battlefield 6. Can you make my
    # lights flash to the surroundings" - and, asked which half he meant, "I want
    # the on-screen color... I want the screen effect like I wanted for my TV."
    #
    # ~\screenlights\capture.py reads his PRIMARY monitor over Desktop
    # Duplication and publishes zone colours here. This loop is a pure CONSUMER,
    # exactly as it is of the voice bus and the music bus - if the capture is not
    # running, not installed, or crashes, nothing here changes.
    #
    # !! IT REUSES THE 'music' STATE ON PURPOSE, and this is the whole reason the
    # change is small. Every surface below already has a 'music' case that takes
    # its colour from $bR/$bG/$bB and its brightness from $amp. Inventing a
    # 'screen' state would mean adding a case to all fifteen of those chains -
    # which is EXACTLY the bug the music build hit ("it doesn't switch to the
    # music"), where detection worked perfectly while every surface still
    # rendered idle blue. Screen mode sets the same two variables and inherits
    # all of it. Do not "clean this up" into its own state without adding a case
    # to every surface chain first.
    #
    # !! SCREEN OUTRANKS MUSIC, and both yield to Jarvis. Screen is the thing he
    # actually asked for, and he plays on headphones so the music bus is not
    # meaningfully live during a match anyway. Neither one may outrank a STATUS
    # indicator - see the music block below for why that rule exists.
    [string]  $ScreenBus = (Join-Path $env:USERPROFILE 'screenlights\.screen_bus'),
    [double]  $ScreenFreshSec = 1.5,
    [switch]  $NoScreen,
    # !! RUNTIME OFF SWITCH, same shape and same reason as $MusicOffFlag: a
    # parameter would need the render loop restarted, which drops every light for
    # ~15 s just to silence them.
    [string]  $ScreenOffFlag = (Join-Path $PSScriptRoot 'SCREEN_OFF'),
    # ⭐ Swaps the red and blue channels for the GPU only.
    #
    # Kept OFF. The reasoning that first switched it on is deleted rather than
    # left here, because it was wrong and two sources of truth is how it would
    # get switched back on. The one part still worth keeping:
    #
    # ⚠ The very first colour-cycle test hid this. It ran red, green, blue and
    # Brian reported "red, green, blue" - but under a swap that same sequence
    # displays as blue, green, red, and neither of us noticed the order was
    # reversed because all three colours appeared. **A cycle test proves a device
    # is reachable; it does NOT prove the channels are mapped correctly. Use a
    # single unmistakable colour, or check the order explicitly.**
    # ---------------------------------------------------------------------
    # DISPROVED AND TURNED OFF 2026-08-01. Everything above this line is wrong.
    #
    # MEASURED, not reasoned: with the render loop paused, this card was sent a
    # raw byte0=255, byte1=0, byte2=0 at full brightness - no punch curve, no
    # swap, no envelope - and Brian reported RED. So OpenRGB's byte0 drives the
    # physical RED emitter and this card is ordinary RGB. The swap was inverting
    # it, and had been the whole time.
    #
    # What that swap actually produced: our speaking red came out BLUE and our
    # idle blue came out RED. Every confusing observation of this card today is
    # explained by it, INCLUDING the two that got misdiagnosed:
    #   - "even through your talking it stayed blue" - that WAS the syllable red,
    #     inverted. The effect was working; the colour was flipped.
    #   - "right now it's just red" after Armoury Crate was stopped - written up
    #     at the time as the LED latching on Armoury Crate's last colour. It was
    #     not. It was our own idle blue, inverted. (Armoury Crate WAS genuinely
    #     causing the magenta - that half stands.)
    #
    # The trap that hid it for so long is worth keeping: Brian only ever glances
    # at the logo just after a sentence ends, which is still inside the ~2.5 s
    # release tail - so "it's blue" was a report about the SPEAKING colour every
    # time, never about idle. **When a report and the code disagree, pin down
    # WHEN the observation was taken before theorising about why.**
    [bool]  $GpuSwapRB = $false,
    # ⚠ Gain multiplies all three colour channels, which pushes everything
    # toward white and DESATURATES it - Brian caught this immediately ("not as
    # dark red... not as dark blue as the other one"). A saturated red is
    # already at full channel value, so there is no headroom to brighten it
    # without whitening it. Left at 1.0 deliberately. Do not raise it to make
    # something "brighter" - it makes it paler, not brighter.
    [double]$FanGain     = 1.0,
    [bool]  $FanReverse  = $false,
    # Rate-limited below the 30 fps the keyboard runs at: these are USB HID and
    # I2C devices with far fewer LEDs, and there is nothing to gain from
    # hammering them inside the same frame budget.
    # Raised 15 -> 30 on 2026-08-01, purely to make the Knight Rider scanner
    # renderable: at $FanScanSpeed 16 a step lasts ~0.065 s, so 15/sec would give
    # barely one frame per step and steps would be skipped outright.
    #
    # ⚠ Drives the fans AND the addressable strip. The GPU is NOT affected - it
    # has its own much slower gate ($GpuFps), which exists precisely because that
    # card could not drain 15/sec. If the fans or the strip ever start lagging
    # behind the voice or smearing, this is the first number to put back to 15:
    # it is the same failure mode the GPU had, and the symptom is the effect
    # arriving late rather than any error in the log.
    [int]   $ExtrasFps   = 30,
    # Escape hatch, same purpose as -NoMouse.
    [switch]$NoExtras,
    # Escape hatch: skips the Chroma path entirely. Here so the mouse can be
    # ruled out in one flag if it is ever suspected of costing frames.
    [switch]$NoMouse
)

# HSV -> RGB, h in degrees. Used for the speaking bloom's outward colour
# sweep: red at the centre, running up through orange/yellow/green toward
# blue at the edges, so how far the colour travels is itself a volume cue.
function Convert-HsvToRgb {
    param([double]$H, [double]$S, [double]$V)
    $H = $H % 360; if ($H -lt 0) { $H += 360 }
    $c = $V * $S
    $x = $c * (1 - [Math]::Abs((($H / 60) % 2) - 1))
    $m = $V - $c
    switch ([int][Math]::Floor($H / 60)) {
        0 { $r=$c; $g=$x; $b=0 }
        1 { $r=$x; $g=$c; $b=0 }
        2 { $r=0;  $g=$c; $b=$x }
        3 { $r=0;  $g=$x; $b=$c }
        4 { $r=$x; $g=0;  $b=$c }
        default { $r=$c; $g=0; $b=$x }
    }
    return @(($r + $m), ($g + $m), ($b + $m))
}

# ⚠ Resolved from $PSScriptRoot, never a hardcoded C:\Users\bclar path.
# Fixed 2026-08-01: these were absolute. This script itself lives outside
# OneDrive so it only breaks if the Windows username differs - but the backup
# copy in `My Jarvis\Code Backup\` IS synced across machines, and CLAUDE.md
# records this same trap biting three separate times (2026-07-30, 07-31, 08-01,
# the last across six desktop launchers at once). Same class, so same fix.
. (Join-Path $PSScriptRoot 'orgb.ps1')
. (Join-Path $PSScriptRoot 'chroma.ps1')
. (Join-Path $PSScriptRoot 'govee.ps1')

$StateFile    = Join-Path $VoiceDir '.voice_state'
$WaveformFile = Join-Path $VoiceDir '.voice_waveform'
$AlertFile    = Join-Path $VoiceDir '.voice_alert'
$WaveFreshSec = 2.0
$LevelScale   = 4.0

function Log($msg) {
    Add-Content -Path $LogFile -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding utf8
}

# Renders one logical strip of $Count LEDs and returns the raw frame bytes.
# Kept as a function taking every input explicitly (rather than a scriptblock
# closing over loop variables) so the keyboard and the RAM group can be painted
# from the same code with different lengths.
function Get-StripFrame {
    param(
        [int]$Count, [string]$Mode, [double]$Amp,
        [double]$BR, [double]$BG, [double]$BB, [double]$Phase,
        # Width is driven SEPARATELY from brightness so the red can breathe.
        # Brian, 2026-08-01: he wanted the red to dim slightly as the white
        # closes in, with the red coming back being what pushes the white out
        # again. Brightness therefore tracks the fast envelope and width tracks
        # a slower one - at the bottom of a dip the band is at its narrowest
        # AND its dimmest, and on the way back up brightness leads width.
        # -1 means "same as $Amp" so non-bloom modes are unaffected.
        [double]$AmpWidth = -1
    )
    if ($AmpWidth -lt 0) { $AmpWidth = $Amp }
    $buf = New-Object byte[] ($Count * 4)
    $ctr = ($Count - 1) / 2.0
    if ($ctr -le 0) { $ctr = 1 }
    for ($i = 0; $i -lt $Count; $i++) {
        $o = $i * 4
        if ($Mode -eq 'bloom') {
            # Louder speech widens the lit band AND lifts brightness. The floor
            # matters more than the maths suggests: at 0.10 the effect was
            # invisible on real hardware, at 0.35 it read but dim. 0.60 works.
            # Sigma scales with strip length so a 48-LED RAM run and a 104-key
            # board bloom to the same PROPORTION, not the same pixel width.
            # Bloom width, tuned by eye against real hardware on 2026-08-01.
            # Edge brightness as a fraction of centre, at full speaking volume:
            #   9.0 / 34.0  -> ~50%  original; read as "bright edges", rejected
            #   6.0 / 22.0  -> ~18%  better, Brian asked for a little less again
            #   4.5 / 16.5  -> ~5%   current (his "0.75 of that") - ACCEPTED
            # Colour is untouched - red centre to white edges is a locked
            # decision. Do NOT fold a colour change in here.
            $sigma = ($Count / 104.0) * (4.5 + 16.5 * $AmpWidth)
            if ($sigma -lt 1) { $sigma = 1 }
            $d = ($i - $ctr) / $sigma
            $v = (0.60 + 0.40 * $Amp) * [Math]::Exp(-0.5 * $d * $d)
            if ($v -lt 0) { $v = 0 } elseif ($v -gt 1) { $v = 1 }
            # Brian's call (2026-08-01): deep red at the centre washing out to
            # white at the edges - NOT the rainbow sweep, which was built first
            # and rejected. Hue stays red; SATURATION falls with distance.
            $sat = 1.0 - ([Math]::Abs($i - $ctr) / $ctr)
            if ($sat -lt 0) { $sat = 0 }
            $rgb = Convert-HsvToRgb 0.0 $sat $v
            $buf[$o]     = [byte][Math]::Round(255 * $rgb[0])
            $buf[$o + 1] = [byte][Math]::Round(255 * $rgb[1])
            $buf[$o + 2] = [byte][Math]::Round(255 * $rgb[2])
            continue
        }
        if ($Mode -eq 'music') {
            # Simple beat pulse: lights stay on, brighten on beat, random color changes
            $hue = $script:musicHue
            $sat = 1.0
            # Lights always on (0.15 minimum), brighten significantly on beat
            $v   = 0.15 + 0.85 * $script:beatFlash
            if ($v -gt 1) { $v = 1 } elseif ($v -lt 0) { $v = 0 }
            $rgb = Convert-HsvToRgb $hue $sat $v
            $buf[$o]     = [byte][Math]::Round(255 * $rgb[0])
            $buf[$o + 1] = [byte][Math]::Round(255 * $rgb[1])
            $buf[$o + 2] = [byte][Math]::Round(255 * $rgb[2])
            continue
        }
        if ($Mode -eq 'scan') {
            $pos = (($Phase / ([Math]::PI * 2)) * $Count)
            $d = [Math]::Abs($i - $pos)
            if ($d -gt $Count / 2) { $d = $Count - $d }
            $w = [Math]::Max(2.0, $Count / 13.0)
            $v = $Amp * [Math]::Exp(-0.5 * [Math]::Pow($d / $w, 2)) + 0.10
        } else {
            $v = $Amp
        }
        if ($v -lt 0) { $v = 0 } elseif ($v -gt 1) { $v = 1 }
        $buf[$o]     = [byte][Math]::Round(255 * $BR * $v)
        $buf[$o + 1] = [byte][Math]::Round(255 * $BG * $v)
        $buf[$o + 2] = [byte][Math]::Round(255 * $BB * $v)
    }
    return $buf
}

# Builds the frame for one strip: the active layer, with the idle blue mixed in
# additively underneath it during the hand-off. Additive rather than a weighted
# blend on purpose - the red is already fading on its own envelope, so adding a
# rising blue underneath lets both be present at once and reads as a genuine
# cross-fade. A weighted blend would cut the red short to make room for the blue.
# Reads $mode/$amp/$ampWidth/$bR/$bG/$bB/$phase/$blueAmp from the render loop.
function Get-BlendedFrame {
    param([int]$N)
    $f = Get-StripFrame $N $mode $amp $bR $bG $bB $phase $ampWidth
    if ($blueAmp -gt 0.002 -and $mode -ne 'flat') {
        $b = Get-StripFrame $N 'flat' $blueAmp 0.10 0.30 0.90 $phase
        for ($k = 0; $k -lt $f.Length; $k++) {
            $s = [int]$f[$k] + [int]$b[$k]
            if ($s -gt 255) { $s = 255 }
            $f[$k] = [byte]$s
        }
    }
    return $f
}

# Returns the single brightest RGB triple from a rendered strip - the "peak" of
# whatever the current frame is. Used for surfaces too small to show a gradient
# (the GPU's single LED, the two motherboard LEDs, the mouse in pulse mode).
#
# Deliberately renders a real strip first rather than recomputing a colour, so
# every envelope, the release tail and the additive blue cross-fade all still
# apply - these surfaces show the peak of the same effect, never a separate one.
function Get-PeakColor {
    param([int]$N = 9)
    $f = Get-BlendedFrame $N
    $bi = 0; $best = -1
    for ($i = 0; $i -lt $N; $i++) {
        $o = $i * 4
        $sum = [int]$f[$o] + [int]$f[$o+1] + [int]$f[$o+2]
        if ($sum -gt $best) { $best = $sum; $bi = $i }
    }
    $b = $bi * 4
    return @($f[$b], $f[$b+1], $f[$b+2])
}

# Builds a frame for a device made of SEVERAL equal-length addressable channels
# by rendering one bloom and repeating it per channel, optionally preceded by a
# fixed-size solid header segment (the ASUS controller's 2 onboard LEDs).
#
# Repeating per channel rather than painting one long strip across all of them
# is deliberate: we do not know which channels actually have hardware attached,
# and a single continuous bloom would leave a populated channel dark whenever
# the bloom's centre happened to sit on an empty one.
function Get-ChannelFrame {
    param(
        [int]$Channels, [int]$PerChannel, [int]$HeaderLeds = 0,
        # Reverse the LED order within each channel. Brian, 2026-08-01: the
        # radiator fans are mounted so he sees the far side of the ring, which
        # made the bloom travel the wrong way round. This mirrors it.
        [bool]$Reverse = $false,
        # Multiplies every channel's brightness before clamping. The bloom's own
        # falloff is tuned for a 104-key board; a fan ring is far smaller and
        # much further from his eye, so it needs lifting to read at all.
        [double]$Gain = 1.0
    )
    $total = $HeaderLeds + ($Channels * $PerChannel)
    $buf = New-Object byte[] ($total * 4)
    if ($HeaderLeds -gt 0) {
        $pk = Get-PeakColor
        for ($i = 0; $i -lt $HeaderLeds; $i++) {
            $o = $i * 4; $buf[$o] = $pk[0]; $buf[$o+1] = $pk[1]; $buf[$o+2] = $pk[2]
        }
    }
    $one = Get-BlendedFrame $PerChannel

    if ($Reverse) {
        $rev = New-Object byte[] $one.Length
        for ($i = 0; $i -lt $PerChannel; $i++) {
            $src = ($PerChannel - 1 - $i) * 4
            $dst = $i * 4
            $rev[$dst] = $one[$src]; $rev[$dst+1] = $one[$src+1]; $rev[$dst+2] = $one[$src+2]
        }
        $one = $rev
    }

    if ($Gain -ne 1.0) {
        for ($i = 0; $i -lt $PerChannel; $i++) {
            $o = $i * 4
            for ($k = 0; $k -lt 3; $k++) {
                $v = [int][Math]::Round($one[$o + $k] * $Gain)
                if ($v -gt 255) { $v = 255 }
                $one[$o + $k] = [byte]$v
            }
        }
    }

    for ($ch = 0; $ch -lt $Channels; $ch++) {
        [Array]::Copy($one, 0, $buf, ($HeaderLeds + $ch * $PerChannel) * 4, $one.Length)
    }
    return $buf
}

# ⭐ PURE palette for the fans - deliberately NOT the keyboard's blend.
#
# Brian, 2026-08-01, after three failed correction attempts: "more blue than
# that and more white than that, like an LED white and an LED blue."
#
# The real cause was never gain or emitter balance. The idle blue every other
# surface uses is `0.10 / 0.30 / 0.90` - it carries a deliberate third of GREEN,
# which reads fine spread across 104 keys but reads as teal on a diffused fan
# ring. Likewise the "white" edges are the bloom's desaturated tail, not a real
# white. You cannot correct green back out of a colour that has green in it by
# scaling channels; every attempt just traded one wrong colour for another.
#
# So the fans get flat, primary colours and take only their BRIGHTNESS from the
# shared envelopes - so they still breathe in time with everything else, they
# just do it in pure blue, pure white and pure red.
# Reads $state/$alert/$releasing/$amp/$blueAmp from the render loop.
function Get-FanColors {
    $blue = @(0, 0, 255)
    $sB = 0.0; $bB = 0.0
    $cBase = @(0,0,0); $oBase = @(0,0,0)
    if ($alert) {
        $cBase = @(255,0,0); $oBase = @(255,0,0); $sB = $amp
    } elseif ($state -eq 'speaking' -or $releasing) {
        $cBase = @(255,0,0); $oBase = @(255,255,255); $sB = $amp; $bB = $blueAmp
    } elseif ($state -eq 'music' -or $state -eq 'screen') {
        # Spectrum- or screen-derived colour; $bR/$bG/$bB are 0..1 here, these
        # want 0..255. Both states hand a finished colour to this surface.
        $mc = @([int](255*$bR), [int](255*$bG), [int](255*$bB))
        $cBase = $mc; $oBase = $mc; $sB = $amp
    } elseif ($state -eq 'thinking') {
        $cBase = @(255,130,0); $oBase = @(255,130,0); $sB = $amp
    } elseif ($state -eq 'listening') {
        $cBase = @(0,255,90); $oBase = @(0,255,90); $sB = $amp
    } else {
        $bB = $amp        # idle: pure blue only
    }
    $c = New-Object byte[] 3
    $o = New-Object byte[] 3
    for ($k = 0; $k -lt 3; $k++) {
        $cv = [int][Math]::Round($cBase[$k] * $sB + $blue[$k] * $bB); if ($cv -gt 255) { $cv = 255 }
        $ov = [int][Math]::Round($oBase[$k] * $sB + $blue[$k] * $bB); if ($ov -gt 255) { $ov = 255 }
        $c[$k] = [byte]$cv; $o[$k] = [byte]$ov
    }
    return @{ Centre = $c; Outer = $o }
}

# Saturate-then-dim, in place, on an already-built frame.
#
# Per LED: scale the triple so its brightest channel reaches 255 - full
# saturation with the hue untouched - then re-apply brightness through a
# floor/span/gamma curve. This is the operation that adds punch WITHOUT
# whitening; multiplying all three channels only ever desaturates (learned the
# hard way on the fans, 2026-08-01).
function Convert-ToPunch {
    param([byte[]]$Frame, [int]$LedCount, [double]$Floor, [double]$Span, [double]$Gamma, [bool]$Invert = $false)
    for ($i = 0; $i -lt $LedCount; $i++) {
        $o = $i * 4
        $r = [double]$Frame[$o]; $g = [double]$Frame[$o+1]; $b = [double]$Frame[$o+2]
        $max = [Math]::Max($r, [Math]::Max($g, $b))
        if ($max -lt 1) { $Frame[$o]=0; $Frame[$o+1]=0; $Frame[$o+2]=0; continue }
        $t = [Math]::Min(1.0, $max / 255.0)
        if ($Gamma -ne 1.0) { $t = [Math]::Pow($t, $Gamma) }
        # Inverted: sits bright and DARKENS as the voice gets louder. Brian's
        # call for the strip, 2026-08-01 - "just light it up and then turn it
        # off with your voice" - because a bright strip dropping out reads far
        # more clearly than a dim one lifting.
        if ($Invert) { $t = 1.0 - $t }
        $k = (255.0 / $max) * ($Floor + $Span * $t)
        $vr = [int][Math]::Round($r * $k); if ($vr -gt 255) { $vr = 255 }
        $vg = [int][Math]::Round($g * $k); if ($vg -gt 255) { $vg = 255 }
        $vb = [int][Math]::Round($b * $k); if ($vb -gt 255) { $vb = 255 }
        $Frame[$o] = [byte]$vr; $Frame[$o+1] = [byte]$vg; $Frame[$o+2] = [byte]$vb
    }
}

# One addressable channel rendered as a LINEAR RAMP, not a bloom.
#
# Brian, 2026-08-01: "make the strip more red at the bottom and more white at
# the top. It just barely shows white when you talk."
#
# Two things were wrong with reusing the keyboard's bloom here. It is CENTRED,
# so red sat in the middle with white at BOTH ends rather than running bottom to
# top. And its falloff is deliberately tuned so the edges are about 5% of centre
# brightness - a locked keyboard decision - which is precisely why the white
# barely registered. A gradient fixes both: brightness stays full along the
# whole strip and only the saturation travels, so the white end is genuinely
# white and genuinely bright.
#
# Reads $state/$alert/$releasing/$amp/$blueAmp from the render loop.
function Get-AuraStripFrame {
    param([int]$N)
    $buf = New-Object byte[] ($N * 4)
    for ($i = 0; $i -lt $N; $i++) {
        $o = $i * 4
        $pos = 0.0
        if ($N -gt 1) { $pos = $i / [double]($N - 1) }
        if ($AuraFlip) { $pos = 1.0 - $pos }

        $r = 0.0; $g = 0.0; $b = 0.0
        if ($alert) {
            $r = $amp
        } elseif ($state -eq 'speaking' -or $releasing) {
            # Saturation 1 at the bottom (pure red) ramping to 0 at the top
            # (white). Brightness is flat - the ramp is colour only.
            $sat = 1.0 - ($pos * $AuraRampGain)
            if ($sat -lt 0) { $sat = 0 }
            $rgb = Convert-HsvToRgb 0.0 $sat $amp
            $r = $rgb[0]; $g = $rgb[1]; $b = $rgb[2]
        } elseif ($state -eq 'music' -or $state -eq 'screen') {
            $r = $bR * $amp; $g = $bG * $amp; $b = $bB * $amp
        } elseif ($state -eq 'thinking') {
            $rgb = Convert-HsvToRgb 32.0 1.0 $amp
            $r = $rgb[0]; $g = $rgb[1]; $b = $rgb[2]
        } elseif ($state -eq 'listening') {
            $rgb = Convert-HsvToRgb 140.0 1.0 $amp
            $r = $rgb[0]; $g = $rgb[1]; $b = $rgb[2]
        }
        # Idle blue, mixed in additively on the same cross-fade as every other
        # surface so the hand-off stays in step with the keyboard.
        #
        # !! 'screen' IS EXCLUDED. This adds a FULL $amp of blue to any state not
        # named here, which would tint every screen colour toward blue - and blue
        # contamination is exactly the symptom Brian reported. Music is left in
        # the list on purpose: that look is accepted and is not being changed
        # here, however odd it is.
        $bl = 0.0
        if ($state -eq 'speaking' -or $releasing) { $bl = $blueAmp }
        elseif (-not $alert -and $state -ne 'thinking' -and $state -ne 'listening' -and $state -ne 'screen') { $bl = $amp }
        $b += $bl

        $vr = [int][Math]::Round(255 * $r); if ($vr -gt 255) { $vr = 255 } elseif ($vr -lt 0) { $vr = 0 }
        $vg = [int][Math]::Round(255 * $g); if ($vg -gt 255) { $vg = 255 } elseif ($vg -lt 0) { $vg = 0 }
        $vb = [int][Math]::Round(255 * $b); if ($vb -gt 255) { $vb = 255 } elseif ($vb -lt 0) { $vb = 0 }
        $buf[$o] = [byte]$vr; $buf[$o+1] = [byte]$vg; $buf[$o+2] = [byte]$vb
    }
    return $buf
}

# The flat state+syllable colour now used by the keyboard, the RAM and the
# mouse - the effect Brian chose over the bloom on 2026-08-01.
#
# One flat colour across the whole surface: the state sets the hue (blue idle,
# amber thinking, green listening, red on alert) and a fast envelope driven by
# the RAW per-frame waveform flashes red on top for each syllable. Taking the
# max rather than adding keeps the red pure instead of tinting it toward
# whatever colour is underneath.
# Reads $state/$alert/$releasing/$amp/$blueAmp/$ttsLive/$voiceEnv from the loop.
# !! $ttsLive, NOT $waveLive. Since 2026-08-02 the bus also carries Brian's mic,
# and only Jarvis's own voice may drive the red syllable layer.
function Get-FlatColor {
    # EnvOverride lets a caller supply its own voice envelope instead of the
    # shared 30 fps one. Negative means "use the shared one" - the default, so
    # the keyboard, RAM and mouse are unaffected. The GPU passes its peak-hold
    # value here because it only writes ~5x/sec and would otherwise miss most
    # syllables. Kept as one function deliberately: the whole point of pointing
    # the GPU at Get-FlatColor was that these surfaces can never drift apart.
    param([double]$EnvOverride = -1.0)
    $env = $voiceEnv
    if ($EnvOverride -ge 0) { $env = $EnvOverride }
    $fr = 0.0; $fg = 0.0; $fb = 0.0
    if ($alert)                       { $fr = $amp }
    elseif ($state -eq 'music' -or $state -eq 'screen') { $fr = $amp * $bR; $fg = $amp * $bG; $fb = $amp * $bB }
    elseif ($state -eq 'thinking')    { $fr = $amp; $fg = $amp * 0.51 }
    elseif ($state -eq 'listening')   { $fg = $amp; $fb = $amp * 0.35 }
    elseif ($state -eq 'speaking' -or $releasing) { $fb = $blueAmp }
    else                              { $fb = $amp }
    if ($ttsLive) { $fr = [Math]::Max($fr, $env) }
    $vr = [int][Math]::Round(255 * $fr); if ($vr -gt 255) { $vr = 255 }
    $vg = [int][Math]::Round(255 * $fg); if ($vg -gt 255) { $vg = 255 }
    $vb = [int][Math]::Round(255 * $fb); if ($vb -gt 255) { $vb = 255 }
    return @([byte]$vr, [byte]$vg, [byte]$vb)
}

# Fills a whole device with one colour.
function Get-FlatFrame {
    param([int]$N, [byte[]]$Rgb)
    $buf = New-Object byte[] ($N * 4)
    for ($i = 0; $i -lt $N; $i++) { $o = $i * 4; $buf[$o] = $Rgb[0]; $buf[$o+1] = $Rgb[1]; $buf[$o+2] = $Rgb[2] }
    return $buf
}

function Send-Frame {
    param($Conn, [int]$Index, [byte[]]$Colors, [int]$LedCount)
    $p = New-Object byte[] (4 + 2 + $Colors.Length)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$p.Length), 0, $p, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$LedCount), 0, $p, 4, 2)
    [Array]::Copy($Colors, 0, $p, 6, $Colors.Length)
    Send-OrgbPacket $Conn.Stream $Index 1050 $p
}

# --- single instance.
#
# run-voice-line.bat now launches this too, so opening the voice line while a
# copy is already running (or running Start Voice Lights.bat on top of it) would
# put TWO render loops on the SDK at once, fighting frame by frame. Second copy
# just backs out.
#
# Checked BEFORE the stop-file is cleared below: a second instance must not
# delete a STOP that was placed to shut the FIRST one down.
#
# !! REWRITTEN 2026-08-02 AS A PID LOCK. The old guard scanned every
# powershell.exe command line for this script's name, which meant ANY process
# that merely MENTIONED the script counted as a running instance - including the
# shell launching it. That misfired three separate times (2026-08-01 twice,
# 2026-08-02 once), and the last one left Brian's board dark: the launch command
# happened to build a log path as "voice-lights" + ".log", and that one
# contiguous literal was enough for the new loop to see its own parent and quit
# after the old loop had already stopped. The workaround was "remember to
# concatenate every occurrence", which is exactly the kind of rule that holds
# until someone forgets.
#
# The lock records PID **and process start time**. The start time is what makes
# it correct rather than merely better: Windows reuses PIDs, so a stale lock
# whose number now belongs to an unrelated process would otherwise block startup
# forever. Same PID + same start time is genuinely the same process. No command
# line is examined at all, so nothing a caller does to its own command line can
# affect this.
#
# Checked BEFORE the stop-file is cleared below: a second instance must not
# delete a STOP that was placed to shut the FIRST one down.
$LockFile = Join-Path $PSScriptRoot ('voice-' + 'lights' + '.pid')

function Get-RunningLoopPid {
    if (-not (Test-Path $LockFile)) { return 0 }
    try {
        $parts = ((Get-Content -LiteralPath $LockFile -Raw).Trim()) -split '\|'
        $lockPid = [int]$parts[0]
        if ($lockPid -eq $PID) { return 0 }
        $p = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        if (-not $p) { return 0 }                      # stale: process is gone
        if ($parts.Count -gt 1) {
            $ticks = [long]$parts[1]
            if ($ticks -gt 0 -and $p.StartTime.Ticks -ne $ticks) { return 0 }   # PID reused
        }
        return $lockPid
    } catch { return 0 }
}

$runningPid = Get-RunningLoopPid
if ($runningPid -gt 0) {
    Log "another render loop is already running (pid $runningPid) - this copy is exiting"
    exit 0
}
try {
    "$PID|$((Get-Process -Id $PID).StartTime.Ticks)" | Set-Content -LiteralPath $LockFile -Encoding ASCII
} catch {
    Log "could not write the pid lock ($($_.Exception.Message)) - continuing anyway"
}

if (Test-Path $StopFile) { Remove-Item $StopFile -Force }
Log "=== starting - target '$DeviceMatch', $Fps fps, bus '$VoiceDir' ==="

# --- Build the device set.
#
# Two independent "strips", each getting its own centred bloom:
#   keyboard : the Vulcan's 104 keys, one strip
#   ram      : every DRAM stick concatenated end-to-end into ONE virtual
#              strip, so the bloom sweeps across the sticks as a group
#              rather than each stick pulsing identically.
#
# Devices are matched by NAME, never by a fixed index - indexes shift every
# time a device is added, removed or re-detected, and writing to a stale
# index silently paints the wrong hardware.
#
# Note the deliberate oddity: one controller reports itself as the
# motherboard but carries 8 LEDs, and lighting it lit a RAM stick. It is
# grouped with the RAM on that evidence rather than on its name.
$conn = $null
$keyboard = $null          # @{ Idx; Leds }
$ramParts = @()            # ordered list of @{ Idx; Leds; Offset; Addr }
$ramTotal = 0

# Two of the eight sticks are only visible because ene-smbus.ps1 moves them off
# the addresses firmware assigns (0x3E/0x3F, which OpenRGB never scans) onto
# ones it does (0x70/0x71). That rescue makes them appear FIRST in OpenRGB's
# enumeration even though they sit sixth and seventh in the row - so painting
# in enumeration order would scramble the bloom's travel across the sticks.
# ram-order.json records current address -> firmware address so paint order
# follows the physical row. Missing or unreadable, we fall back to enumeration
# order and still light everything.
# Returns: current SMBus address -> sort key, where the sort key is the PHYSICAL
# DIMM SLOT NUMBER. Composed from two files:
#
#   ram-order.json  current address -> firmware address. Rewritten by
#                   ene-smbus.ps1 -Action autofix on every boot, because the
#                   rescued sticks move (0x3E->0x70, 0x3F->0x71).
#   ram-slots.json  firmware address -> physical slot. Measured by eye on
#                   2026-08-01 and stable, since firmware assigns the same
#                   addresses at every POST. Only changes if Brian physically
#                   moves sticks between slots.
#
# ADDRESS ORDER IS NOT SLOT ORDER on this board - measured, not assumed:
#   slot  1 2 3 4 5 6 7 8
#   addr 40 3F 3E 3D 39 3A 3B 3C
# Two banks of four, the first counted DOWN and the second UP (DIMMs sit on
# both sides of the socket). Painting in address order made the bloom start in
# the middle of the row, run off one end, then jump to the far end and run
# backwards - which is exactly what Brian saw.
function Get-RamSortMap {
    param(
        [string]$OrderPath = 'C:\Users\bclar\openrgb\ram-order.json',
        [string]$SlotPath  = 'C:\Users\bclar\openrgb\ram-slots.json'
    )
    $currentToFirmware = @{}
    $firmwareToSlot    = @{}

    try {
        if (Test-Path $OrderPath) {
            foreach ($e in (Get-Content $OrderPath -Raw | ConvertFrom-Json)) { $currentToFirmware[[int]$e.current] = [int]$e.original }
        } else {
            Log 'no ram-order.json - did the boot task run? falling back to enumeration order'
        }
    } catch {
        Log "ram-order.json unreadable ($($_.Exception.Message)) - falling back to enumeration order"
    }

    try {
        if (Test-Path $SlotPath) {
            foreach ($e in (Get-Content $SlotPath -Raw | ConvertFrom-Json)) { $firmwareToSlot[[int]$e.firmware] = [int]$e.slot }
        } else {
            Log 'no ram-slots.json - falling back to address order, which is KNOWN WRONG on this board'
        }
    } catch {
        Log "ram-slots.json unreadable ($($_.Exception.Message)) - falling back to address order"
    }

    $sort = @{}
    foreach ($cur in $currentToFirmware.Keys) {
        $fw = $currentToFirmware[$cur]
        $sort[$cur] = if ($firmwareToSlot.ContainsKey($fw)) { $firmwareToSlot[$fw] } else { $fw }
    }
    return $sort
}

# Devices are matched by NAME, never by a fixed index - indexes shift every
# time a device is added, removed or re-detected, and writing to a stale index
# silently paints the wrong hardware.
function Get-DeviceSet {
    param($Conn, [string]$Match)
    $kb = $null
    $parts = @()
    $sortMap = Get-RamSortMap

    # OpenRGB registers controllers PROGRESSIVELY as it detects them - the RAM
    # sticks alone take about 400 ms each - and a client that connects mid-scan
    # gets a partial list with no notification when the rest arrive. Observed
    # on 2026-08-01: a reconnect during service startup returned 2 devices and
    # no keyboard, and the loop then considered itself healthy and painted 2 of
    # 8 sticks indefinitely. So: wait for the count to STOP CHANGING before
    # trusting it, rather than taking the first answer.
    $n = Get-OrgbControllerCount $Conn
    $stable = 0
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1000
        $n2 = Get-OrgbControllerCount $Conn
        if ($n2 -eq $n) {
            $stable++
            if ($stable -ge 3) { break }
        } else {
            $n = $n2
            $stable = 0
        }
    }
    if ($stable -lt 3) { Log "WARNING: device count never settled (last=$n) - proceeding anyway" }

    $tt = $null; $aura = $null; $gpu = $null

    for ($i = 0; $i -lt $n; $i++) {
        $c = Get-OrgbController $Conn $i

        # --- addressable surfaces, handled BEFORE the zero-LED skip below.
        # These legitimately report 0 LEDs until their channel size is declared,
        # so the ordinary "no LEDs, ignore it" guard would discard them forever.
        if (-not $NoExtras) {
            if ($c.Name -match 'Thermaltake') {
                for ($z = 0; $z -lt $c.Zones; $z++) { try { Set-OrgbZoneSize $Conn $i $z $TtLedsPerChannel } catch { } }
                Start-Sleep -Milliseconds 400
                $re = Get-OrgbController $Conn $i
                if ($re.Leds -gt 0) {
                    $tt = @{ Idx = $i; Leds = $re.Leds; Channels = $c.Zones; PerChannel = $TtLedsPerChannel; Name = $c.Name }
                } else { Log "fans: zone resize did not take on '$($c.Name)' - skipping" }
                continue
            }
            # The motherboard's own Aura controller: zone 0 is 2 onboard LEDs,
            # zones 1..n are the addressable headers. Matched on HID location so
            # it can never be confused with the 8-LED RAM stick that OpenRGB
            # mislabels with the same board name at SMBus 0x40.
            if ($c.Name -match 'TRX40' -and $c.Location -match 'HID:') {
                for ($z = 1; $z -lt $c.Zones; $z++) { try { Set-OrgbZoneSize $Conn $i $z $AuraLedsPerChannel } catch { } }
                Start-Sleep -Milliseconds 400
                $re = Get-OrgbController $Conn $i
                if ($re.Leds -gt 2) {
                    $aura = @{ Idx = $i; Leds = $re.Leds; Channels = ($c.Zones - 1); PerChannel = $AuraLedsPerChannel; Header = 2; Name = $c.Name }
                } else { Log "aura: addressable resize did not take on '$($c.Name)' - skipping" }
                continue
            }
            if ($c.Name -match 'GeForce|RTX|Radeon' -and $c.Leds -gt 0) {
                $gpu = @{ Idx = $i; Leds = $c.Leds; Name = $c.Name }
                continue
            }
        }

        if ($c.Leds -le 0) { continue }
        if ($c.Name -match $Match) {
            if (-not $kb) { $kb = @{ Idx = $i; Leds = $c.Leds; Name = $c.Name } }
        }
        elseif ($c.Name -match 'ENE DRAM' -or ($c.Name -match 'TRX40' -and $c.Leds -eq 8)) {
            $addr = if ($c.Location -match 'address 0x([0-9A-Fa-f]+)') { [Convert]::ToInt32($matches[1], 16) } else { 0xFFFF }
            $parts += @{ Idx = $i; Leds = $c.Leds; Offset = 0; Addr = $addr; Name = $c.Name; Slot = '?' }
        }
    }
    # Sort by PHYSICAL SLOT so the bloom sweeps cleanly along the row.
    $parts = @($parts | Sort-Object @{ Expression = { if ($sortMap.ContainsKey($_.Addr)) { $sortMap[$_.Addr] } else { $_.Addr } } })
    $total = 0
    foreach ($p in $parts) { $p.Slot = $(if ($sortMap.ContainsKey($p.Addr)) { $sortMap[$p.Addr] } else { '?' }); $p.Offset = $total; $total += $p.Leds }
    return @{ Keyboard = $kb; RamParts = $parts; RamTotal = $total; Fans = $tt; Aura = $aura; Gpu = $gpu }
}

try {
    $conn = Connect-Orgb -ClientName 'Jarvis Voice Lights'
    $set = Get-DeviceSet $conn $DeviceMatch
    $keyboard = $set.Keyboard
    $ramParts = $set.RamParts
    $ramTotal = $set.RamTotal
    $fans     = $set.Fans
    $aura     = $set.Aura
    $gpu      = $set.Gpu
    if ($keyboard) { Log "keyboard: [$($keyboard.Idx)] $($keyboard.Name), $($keyboard.Leds) leds" }
    foreach ($p in $ramParts) { Log ("ram part: slot {0} = [{1}] {2}, {3} leds at 0x{4:X2} (offset {5})" -f $p.Slot, $p.Idx, $p.Name, $p.Leds, $p.Addr, $p.Offset) }
    if ($fans) { Log ("fans: [{0}] {1}, {2} channels x {3} = {4} leds" -f $fans.Idx, $fans.Name, $fans.Channels, $fans.PerChannel, $fans.Leds) }
    if ($aura) { Log ("aura: [{0}] {1}, {2} onboard + {3} channels x {4} = {5} leds" -f $aura.Idx, $aura.Name, $aura.Header, $aura.Channels, $aura.PerChannel, $aura.Leds) }
    if ($gpu)  { Log ("gpu : [{0}] {1}, {2} led(s)" -f $gpu.Idx, $gpu.Name, $gpu.Leds) }
} catch { Log "FATAL connect: $($_.Exception.Message)"; exit 1 }

if (-not $keyboard -and $ramParts.Count -eq 0) { Log "FATAL: no keyboard and no RAM found"; exit 1 }
Log "device set: keyboard=$(if($keyboard){'yes'}else{'no'})  ramParts=$($ramParts.Count)  ramLeds=$ramTotal"

foreach ($d in @($keyboard) + $ramParts + @($fans) + @($aura) + @($gpu)) { if ($d) { try { Set-OrgbCustomMode $conn $d.Idx } catch { Log "custom mode failed on $($d.Idx): $($_.Exception.Message)" } } }
Start-Sleep -Milliseconds 400

$devIdx   = if ($keyboard) { $keyboard.Idx }  else { $ramParts[0].Idx }
$ledCount = if ($keyboard) { $keyboard.Leds } else { $ramParts[0].Leds }

$frameMs  = [int](1000 / $Fps)
$level    = 0.0
$phase    = 0.0
$colors   = New-Object byte[] ($ledCount * 4)
$center   = ($ledCount - 1) / 2.0
$sw       = [Diagnostics.Stopwatch]::StartNew()
$pollErrs = 0
$frames   = 0
$peakSeen = 0.0

# Recovery state. See the re-discovery block in the loop for why this is a
# flag rather than something driven off send failures.
$needsDiscovery  = $false
$discoveryTries  = 0
$nextDiscoveryAt = Get-Date
$lastBeat        = Get-Date

# --- Chroma (the mouse). Entirely separate from the OpenRGB path above.
#
# Its own connection, its own recovery, its own failure counter - so a dead
# Chroma server can never flag the OpenRGB devices for re-discovery, and a dead
# OpenRGB can never take the mouse down. Opening it is best-effort: a failure
# here is logged and the loop runs mouse-less rather than exiting.
# --- extras (fans / aura addressable / GPU) pacing and failure counters.
# Their own counters deliberately: an extras failure must never be mistaken for
# an OpenRGB outage and must never flag the keyboard and RAM for re-discovery.
$auraEnv         = 0.0      # the strip's own fast envelope, see $AuraStyle 'fade'
$voiceEnv        = 0.0      # shared 30 fps envelope for keyboard / RAM / mouse
# The GPU updates ~5x/sec, so it would otherwise sample whatever instant it
# happened to land on and miss most syllable peaks entirely. Instead every 30 fps
# frame folds its envelope into this running maximum, and each GPU write sends
# the LOUDEST moment since the previous one, then clears it. That is what turns
# a slow surface into something that still reads as flashing rather than mush.
$script:gpuPeakEnv = 0.0
$script:gpuSendAt  = [DateTime]::MinValue
# Per-fan brightness for the Knight Rider scanner, held BETWEEN frames so a fan
# keeps glowing after the head has moved off it. That persistence IS the trail:
# the decay is over TIME, not distance. A spatial falloff was tried twice and
# rejected both times - see the scanner block.
$script:fanScanLv = @(0.0, 0.0, 0.0)
# Room-lighting state (Govee / ChromaLink). All dormant unless -UseChromaLink or
# -GoveeIps is passed - see the room lighting block in the render loop.
$script:roomSendAt    = [DateTime]::MinValue
$script:nextLinkTryAt = [DateTime]::MinValue
$script:roomPeakEnv   = 0.0
$script:roomFails     = 0
# Next time segment mode gets (re-)armed on every Govee lamp. MinValue means
# "arm on the very first room frame" - see the render block for why it repeats.
$script:goveeArmAt    = [DateTime]::MinValue
# Per-lamp records: @{ Ip; Name; Segments }. Populated from govee-lamps.json, or
# synthesised below from -GoveeIps when an address is passed on the command line.
$script:GoveeLamps    = @()
# Music mode state. beatFlash decays over frames so a beat is visible on
# surfaces that only redraw a few times a second.
$script:beatFlash     = 0.0
$script:musicErrs     = 0
# Band energies published for Get-StripFrame's 'music' mode, and the drifting
# hue that keeps the palette moving.
$script:mBassV        = 0.0
$script:mMidV         = 0.0
$script:mTrebV        = 0.0
$script:musicHue      = 200.0
$script:musicSpread   = 45.0     # degrees of hue across a strip, style 0 only
$script:musicPalAt    = [DateTime]::MinValue
$chromaLink           = $null
$extrasFrameMs   = if ($ExtrasFps -gt 0) { [int](1000 / $ExtrasFps) } else { 0 }
$lastExtrasAt    = [DateTime]::MinValue
$extrasFails     = 0

$chroma          = $null
$chromaFrameMs   = if ($MouseFps -gt 0) { [int](1000 / $MouseFps) } else { 0 }
$lastMouseAt     = [DateTime]::MinValue
$lastChromaBeat  = Get-Date
$nextChromaTryAt = Get-Date
$chromaTries     = 0
$chromaFails     = 0
# Razer drops a session that goes quiet for ~15 s. 5 s leaves room for two
# missed beats before the session is actually lost.
$ChromaBeatSec   = 5.0

if ($NoMouse) {
    Log 'mouse: disabled by -NoMouse'
} else {
    try {
        $chroma = Connect-Chroma
        Log ("mouse: Chroma session {0} open at {1}, painting at $MouseFps fps" -f $chroma.SessionId, $chroma.Uri)
    } catch {
        # Not fatal, by design. The most likely cause is the Chroma SDK services
        # being stopped or Synapse being closed.
        Log "mouse: Chroma unavailable at startup ($($_.Exception.Message)) - continuing without it, will keep retrying"
        $chroma = $null
    }
}

# Release tail. Brian's call 2026-08-01: without this the board snapped from a
# full red bloom straight to the blue idle breathe the moment the waveform went
# stale, which looks like the effect being switched off rather than speech
# ending. Now the red is held and allowed to decay away first.
$lastSpeakAt     = Get-Date
$levelWide       = 0.0    # slow envelope, drives bloom WIDTH only
$CrossSec        = 2.5    # red -> blue cross-fade length
$ReleaseSec      = 5.0    # max time to keep holding red after speech stops
$ReleaseFloor    = 0.01   # below this level, hand over to idle

# Unix time, unambiguously. Do NOT compute this as
#   [DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z'
# PowerShell parses that literal into LOCAL time (1969-12-31 19:00 here), so
# every age came out a full UTC-offset too old - the waveform read as stale
# even mid-sentence and the board never left its idle pose.
function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }

# !! READ THE BUS FILES WITH FULL SHARING, INCLUDING Delete.
#
# Every publisher here writes atomically as temp-file + rename. On Windows that
# rename FAILS if a reader holds the target open with default sharing - and the
# reader fails if it lands in the instant between the two. Both sides looked
# healthy while it happened: the analyser logged "bus write failed: access is
# denied", and this loop counted read errors, and neither said why.
#
# FileShare.ReadWrite + Delete is what lets a rename proceed underneath an open
# reader. This is also the long-standing cause of the occasional `pollErrs` on
# the VOICE bus - same pattern, just rarer because that one writes 15x/sec
# instead of 30. Returns $null rather than throwing: a missed frame is nothing,
# and the caller already treats a stale bus as "not live".
function Read-BusText {
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                              ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $sr = New-Object IO.StreamReader($fs)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        return $null
    }
}

# --- Govee lamps from config, so no launcher has to carry an IP -------------
#
# -GoveeIps on the command line always wins. Otherwise govee-lamps.json next to
# this script decides, which keeps the address in ONE place instead of in both
# launchers (and out of the OneDrive-synced desktop .bat entirely).
#
# !! Placed HERE, not up beside the dot-sourcing where it naturally belongs,
# because Log is not defined until well below that point. Calling it earlier
# threw inside this block's own try/catch and left the lamps silently unloaded
# with a completely clean log - the exact silent-failure shape this project has
# been bitten by repeatedly. Do not move it back up.
#
# !! The IP is verified, not assumed. A lamp that does not answer is looked up
# again by its stable device id and the new address logged - otherwise a DHCP
# reassignment after a router reboot would just stop driving the lamp, quietly.
if ($GoveeIps.Count -eq 0) {
    try {
        $lampCfgPath = Join-Path $PSScriptRoot 'govee-lamps.json'
        if (Test-Path $lampCfgPath) {
            $lampCfg  = Get-Content $lampCfgPath -Raw | ConvertFrom-Json
            $resolved = @()
            foreach ($lamp in @($lampCfg.lamps)) {
                if (-not $lamp.ip) { continue }
                $useIp = $null
                if (Get-GoveeStatus -Ip $lamp.ip -WaitMs 900) {
                    $useIp = [string]$lamp.ip
                    Log "govee: $($lamp.name) at $useIp ($($lamp.sku), $($lamp.segments) segments)"
                } else {
                    Log "govee: $($lamp.name) did not answer at $($lamp.ip) - rediscovering by device id"
                    $hit = @(Find-GoveeDevices -WaitMs 2500) | Where-Object { $_.Device -eq $lamp.device } | Select-Object -First 1
                    if ($hit) {
                        $useIp = [string]$hit.Ip
                        Log "govee: $($lamp.name) FOUND at $useIp - update govee-lamps.json"
                    } else {
                        Log "govee: $($lamp.name) not found on the network at all - skipping it"
                    }
                }
                if ($useIp) {
                    # !! SEGMENT COUNT IS CARRIED PER LAMP, not collapsed into one
                    # global. Brian's two lamps are 10 and 8, and the models fail
                    # DIFFERENTLY when the count is wrong: the H6022 truncates
                    # silently, the H6076 rejects the frame and shows nothing at
                    # all. One shared number would therefore have left one lamp
                    # either half-lit or completely dark, with a clean log.
                    $segs = if ($lamp.segments -and [int]$lamp.segments -gt 0) { [int]$lamp.segments } else { $GoveeSegments }
                    # !! Header is PER LAMP too. A wrong header can partially
                    # work - the H618A strip drives only 10 of its 15 zones on
                    # 'govee' and all 15 on 'dreamview', silently. Defaults to
                    # 'govee' because that is what the two lamps use.
                    $hdr = if ($lamp.header) { [string]$lamp.header } else { 'govee' }
                    $resolved += ,@{ Ip = $useIp; Name = [string]$lamp.name; Segments = $segs; Header = $hdr }
                }
            }
            $script:GoveeLamps = $resolved
            $GoveeIps = @($resolved | ForEach-Object { $_.Ip })
        }
    } catch {
        Log "govee: lamp config unreadable, continuing without room lights: $($_.Exception.Message)"
        $GoveeIps = @()
        $script:GoveeLamps = @()
    }
}
# -GoveeIps passed explicitly (or a config that produced none): synthesise the
# per-lamp records so the render block has exactly one shape to work with.
if ($GoveeIps.Count -gt 0 -and $script:GoveeLamps.Count -eq 0) {
    $script:GoveeLamps = @($GoveeIps | ForEach-Object { @{ Ip = $_; Name = $_; Segments = $GoveeSegments; Header = 'govee' } })
    Log "govee: $($GoveeIps.Count) lamp(s) from -GoveeIps at $GoveeSegments segments each"
}

# ===========================================================================
# LIGHT SHOW  (-Show)
# ===========================================================================
#
# ONE function defines the entire show: Get-ShowPixel takes a position on a
# single 0..1 canvas and a time, and returns a colour. Every surface just
# samples its own slice of that canvas. That is the whole trick - it means a
# wave crosses from the room strip, through the lamps, over the fans, across
# the RAM and onto the keyboard automatically, with no per-device choreography
# and no chance of the surfaces disagreeing about where the wave is.
#
# !! Slice widths are hand-weighted, NOT proportional to LED count. The aura
# strip has 182 LEDs and the floor lamp has 8; proportional weighting would
# make a travelling wave crawl across the motherboard for half its journey and
# flick past the whole room in an instant. These are tuned so travel LOOKS even.
if ($Show) {
    # !! ORDER IS BRIAN'S PHYSICAL ROUTE, not device type or LED count.
    # 2026-08-02: "it should go from the strip to the table lamp to the PC to
    # the floor lamp, back to the table lamp, back to the strip." So the canvas
    # is a PATH with the floor lamp at the far end, and travelling effects
    # BOUNCE along it rather than wrapping - the return leg he described is the
    # bounce, not extra canvas.
    # !! TWO PARALLEL CANVASES, AND THIS IS THE WHOLE DESIGN.
    #
    # The first build made ONE path: strip -> table -> [fans, RAM, keyboard,
    # aura, GPU] -> floor. That handed the PC ~60% of the canvas. Brian then
    # said he can see three of the four zones but NOT his PC - "PCs for other
    # people... I'm gonna be doing this for streaming."
    #
    # So from his chair the wave left the table lamp, VANISHED for most of its
    # journey, and reappeared at the floor lamp. He called it "hard to tell."
    # He was right, and it was never a tuning problem: the motion was genuinely
    # invisible for the majority of its length.
    #
    # Fixed by rendering the SAME canvas TWICE, in parallel:
    #   ROOM - the three surfaces he actually sees. This is the path, and it is
    #          continuous, so a wave never leaves his field of view.
    #   PC   - renders the FULL canvas across its own surfaces at the same
    #          instant. Aimed at a camera, not at him. Costs the room nothing.
    # Both span 0..1, so one wave is on both simultaneously.
    $ROOM = @(
        @{ n='strip';  a=0.00; b=0.44 },   # longest physical run, gets the most path
        @{ n='table';  a=0.44; b=0.74 },
        @{ n='floor';  a=0.74; b=1.00 }
    )
    $PC = @(
        @{ n='fans';   a=0.00; b=0.22 },
        @{ n='ram';    a=0.22; b=0.44 },
        @{ n='keyb';   a=0.44; b=0.72 },
        @{ n='aura';   a=0.72; b=0.97 },
        @{ n='gpu';    a=0.97; b=1.00 }
    )
    # Out-and-back along the path. 0->1 over the first half, 1->0 over the second.
    function Bounce([double]$x) { $x = $x % 1.0; if ($x -lt 0.5) { $x * 2 } else { 2 - $x * 2 } }
    function Slice([string]$n) {
        $hit = @($ROOM | Where-Object { $_.n -eq $n })
        if ($hit.Count -eq 0) { $hit = @($PC | Where-Object { $_.n -eq $n }) }
        return $hit[0]
    }
    # Map a surface's own 0..1 index onto its slice of the global canvas.
    function GPos($sl, [double]$f) { $sl.a + ($sl.b - $sl.a) * $f }

    $SHOW_LEN = 76.0
    function Get-ShowPixel {
        param([double]$p, [double]$t)   # p = 0..1 across the whole canvas
        $r=0.0; $g=0.0; $b=0.0

        if ($t -lt 8) {
            # 1. IGNITION - one white point runs the path OUT to the floor lamp
            # and back again, in the dark, leaving a cooling trail behind it.
            $head = Bounce ($t / 16.0)      # /16 so 8 s covers exactly one out-and-back
            $d = [Math]::Abs($p - $head)
            if ($d -lt 0.035) { $v = 1.0 - ($d / 0.035); $r=$v; $g=$v; $b=$v }
            else { $v = 0.14 * [Math]::Exp(-$d * 5.5); $r=$v*0.2; $g=$v*0.4; $b=$v }
        }
        elseif ($t -lt 20) {
            # 2. BLOOM - deep blue floods in from both ends and breathes.
            $u = ($t - 8) / 12.0
            $reach = $u
            $edge = [Math]::Min($p, 1 - $p) * 2      # 0 at the ends, 1 at centre
            $lit = if ((1 - $edge) -le $reach) { 1.0 } else { 0.0 }
            $breath = 0.55 + 0.45 * [Math]::Sin($t * 2.2)
            $v = $lit * (0.25 + 0.75 * $u) * $breath
            $r = $v*0.05; $g = $v*0.30; $b = $v
        }
        elseif ($t -lt 34) {
            # 3. CHASE - three comets at different speeds, hue-separated.
            $u = $t - 20
            $spd = 0.16 + $u * 0.030                 # accelerating
            for ($k=0; $k -lt 3; $k++) {
                # Bounce, not wrap - each comet runs out to the floor lamp and
                # back. Staggered starts keep all three visible at once.
                $head = Bounce (($u * $spd) + $k / 3.0)
                $d = [Math]::Abs($p - $head)
                if ($d -lt 0.16) {
                    $v = [Math]::Pow(1 - ($d / 0.16), 3)
                    # !! Convert-HsvToRgb returns 0..1 FLOATS, not 0..255 bytes.
                    # Dividing by 255 here would render this section black.
                    $c = Convert-HsvToRgb (($k * 120 + $u * 18) % 360) 1.0 $v
                    $r = [Math]::Max($r, $c[0]); $g = [Math]::Max($g, $c[1]); $b = [Math]::Max($b, $c[2])
                }
            }
        }
        elseif ($t -lt 46) {
            # 4. RAINBOW STORM - full-canvas hue sweep, tightening and speeding up.
            $u = ($t - 34) / 12.0
            $cycles = 1 + $u * 3
            $hue = ((($p * $cycles) - ($t * 0.55)) * 360) % 360; if ($hue -lt 0) { $hue += 360 }
            $c = Convert-HsvToRgb $hue 1.0 (0.55 + 0.45 * $u)
            $r=$c[0]; $g=$c[1]; $b=$c[2]
        }
        elseif ($t -lt 56) {
            # 5. STROBE BUILD - accelerating white hits, everything else black.
            $u = $t - 46
            $rate = 2.0 + $u * $u * 0.45
            $ph = ($u * $rate) % 1.0
            if ($ph -lt 0.30) {
                $v = 1 - ($ph / 0.30)
                # narrowing band so the strobe closes toward the centre
                $w = 0.55 - ($u / 10.0) * 0.42
                if ([Math]::Abs($p - 0.5) -lt $w) { $r=$v; $g=$v; $b=$v }
            }
        }
        elseif ($t -lt 58) {
            # 6. BLACKOUT. The whole point of the drop. Do not "improve" this.
        }
        elseif ($t -lt 70) {
            # 7. PAYOFF - full white slam, decaying through amber into deep blue.
            $u = ($t - 58) / 12.0
            $fall = [Math]::Exp(-$u * 3.2)
            $hue = 40 + $u * 175                     # amber -> blue
            $c = Convert-HsvToRgb $hue (0.35 + 0.65 * $u) 1.0
            $r = $fall + (1-$fall) * $c[0] * 0.85
            $g = $fall + (1-$fall) * $c[1] * 0.85
            $b = $fall + (1-$fall) * $c[2] * 0.85
        }
        else {
            # 8. RESOLVE - settle onto the idle blue the loop will take back over.
            $u = ($t - 70) / 6.0
            $breath = 0.55 + 0.45 * [Math]::Sin($t * 1.6)
            $v = (0.85 * (1-$u) + 0.40 * $u) * (0.75 + 0.25*$breath)
            $r=$v*0.10; $g=$v*0.30; $b=$v*0.90
        }
        $q = { param($x) $n=[int][Math]::Round(255*$x); if($n -lt 0){0}elseif($n -gt 255){255}else{$n} }
        return @((& $q $r), (& $q $g), (& $q $b))
    }

    # Fill an OpenRGB byte[] frame by sampling the canvas across a slice.
    function Fill-FromCanvas {
        param([int]$Count, $Sl, [double]$T, [switch]$Reverse)
        $buf = New-Object byte[] ($Count * 4)
        for ($i=0; $i -lt $Count; $i++) {
            $f = if ($Count -le 1) { 0.5 } else { $i / [double]($Count - 1) }
            if ($Reverse) { $f = 1 - $f }
            $c = Get-ShowPixel (GPos $Sl $f) $T
            $o = $i*4; $buf[$o]=[byte]$c[0]; $buf[$o+1]=[byte]$c[1]; $buf[$o+2]=[byte]$c[2]
        }
        return $buf
    }

    Log "=== LIGHT SHOW: $SHOW_LEN s - room path $(($ROOM).Count) surfaces, PC mirror $(($PC).Count) surfaces ==="
    $showChroma = $null
    try { $showChroma = Connect-Chroma } catch { Log "show: no mouse ($($_.Exception.Message))" }
    foreach ($lamp in $script:GoveeLamps) { [void](Enable-GoveeSegments -Ip $lamp.Ip) }
    Start-Sleep -Milliseconds 300

    $swShow = [Diagnostics.Stopwatch]::StartNew()
    $lastGovee = [DateTime]::MinValue
    $lastMouse = [DateTime]::MinValue
    $shownFrames = 0
    while ($swShow.Elapsed.TotalSeconds -lt $SHOW_LEN) {
        $T = $swShow.Elapsed.TotalSeconds
        try {
            if ($keyboard) { Send-Frame $conn $keyboard.Idx (Fill-FromCanvas $keyboard.Leds (Slice 'keyb') $T) $keyboard.Leds }
            if ($ramParts.Count -gt 0) {
                $sl = Slice 'ram'
                $whole = Fill-FromCanvas $ramTotal $sl $T
                foreach ($p in $ramParts) {
                    $slice = New-Object byte[] ($p.Leds * 4)
                    [Array]::Copy($whole, $p.Offset*4, $slice, 0, $p.Leds*4)
                    Send-Frame $conn $p.Idx $slice $p.Leds
                }
            }
            if ($fans) { Send-Frame $conn $fans.Idx (Fill-FromCanvas $fans.Leds (Slice 'fans') $T) $fans.Leds }
            if ($aura) { Send-Frame $conn $aura.Idx (Fill-FromCanvas $aura.Leds (Slice 'aura') $T) $aura.Leds }
            if ($gpu)  { Send-Frame $conn $gpu.Idx  (Fill-FromCanvas $gpu.Leds  (Slice 'gpu')  $T) $gpu.Leds }

            # Govee at its own rate - these are network devices, not USB.
            if (((Get-Date) - $lastGovee).TotalSeconds -ge (1.0/$GoveeFps)) {
                $lastGovee = Get-Date
                foreach ($lamp in $script:GoveeLamps) {
                    $sl = switch -Wildcard ($lamp.Name) { '*Strip*' { Slice 'strip' } '*Floor*' { Slice 'floor' } default { Slice 'table' } }
                    $n = [int]$lamp.Segments
                    $flat = New-Object int[] ($n * 3)
                    for ($i=0; $i -lt $n; $i++) {
                        $f = if ($n -le 1) { 0.5 } else { $i / [double]($n - 1) }
                        $c = Get-ShowPixel (GPos $sl $f) $T
                        $flat[$i*3]=$c[0]; $flat[$i*3+1]=$c[1]; $flat[$i*3+2]=$c[2]
                    }
                    [void](Send-GoveeSegments -Ip $lamp.Ip -Rgb $flat -Header $lamp.Header)
                }
            }
            if ($showChroma -and ((Get-Date) - $lastMouse).TotalSeconds -ge 0.1) {
                $lastMouse = Get-Date
                try { Send-ChromaMouseStrip -Session $showChroma -Strip (Fill-FromCanvas $script:CHROMA_MOUSE_ROWS (Slice 'keyb') $T) } catch { }
            }
            $shownFrames++
        } catch {
            Log "show frame error: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 25
    }
    Log "=== LIGHT SHOW done: $shownFrames frames in $([math]::Round($swShow.Elapsed.TotalSeconds,1)) s ==="

    # Hand everything back exactly the way the normal shutdown path does.
    foreach ($lamp in $script:GoveeLamps) {
        try { [void](Set-GoveeColor -Ip $lamp.Ip -R 25 -G 76 -B 229); Start-Sleep -Milliseconds 50; [void](Disable-GoveeSegments -Ip $lamp.Ip) } catch { }
    }
    try { Close-GoveeStreamClient } catch { }
    if ($showChroma) { try { Disconnect-Chroma $showChroma } catch { } }
    try { Disconnect-Orgb $conn } catch { }
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    exit 0
}

Log "entering render loop"

while (-not (Test-Path $StopFile)) {
    $sw.Restart()

    # ---- read the bus directly, every frame (two tiny local files) ----
    #
    # !! A LIVE WAVEFORM IS NO LONGER PROOF THAT JARVIS IS SPEAKING.
    # Until 2026-08-02 only mouth.py ever published this file, so
    # "fresh audio => speaking" was safe. ears.py now publishes Brian's MIC to
    # the same bus, and that broke this loop in a way that looked deliberate
    # rather than broken: his own voice drove the RED speaking bloom, and the
    # green 'listening' branch below - which was correct and already present -
    # became unreachable, because this check runs before the state file is ever
    # read. Brian caught it by eye: "it shouldn't be breathing with my voice,
    # it should be green."
    #
    # The lesson is the general one: adding a PUBLISHER to a bus means checking
    # every CONSUMER. The Voice Line note names this script as the second
    # consumer in its opening lines, and that warning still got walked past.
    #
    # 'tts' is the default for any older writer that sends no src tag.
    $state = 'idle'; $alert = $false; $target = 0.0
    $waveLive = $false; $ttsLive = $false; $micLive = $false
    try {
        $wtxt = Read-BusText $WaveformFile
        if ($wtxt) {
            $wf = $wtxt | ConvertFrom-Json
            $ts = [double]$wf.ts
            $age = (Get-UnixNow) - $ts
            $samples = $wf.samples
            if ($samples -and $samples.Count -gt 0 -and $age -lt $WaveFreshSec) {
                $waveLive = $true
                $src = if ($wf.PSObject.Properties.Name -contains 'src' -and $wf.src) { ([string]$wf.src).ToLower() } else { 'tts' }
                $micLive = ($src -eq 'mic')
                $ttsLive = -not $micLive
                # !! ONLY Jarvis's voice charges the level envelope. Feeding the
                # mic into it would not just light the red bloom off Brian's
                # speech - it would keep draining red through the release tail
                # afterwards, so every sentence he finished would end in a red
                # flash. The listening branch is flat and breath-driven and does
                # not read $level at all.
                if ($ttsLive) {
                    $sum = 0.0
                    foreach ($s in $samples) { $sum += [Math]::Abs([double]$s) }
                    $target = $sum / $samples.Count * $LevelScale
                    if ($target -gt 1) { $target = 1 }
                }
            }
        }
        if ($ttsLive) {
            $state = 'speaking'
        } elseif ($micLive) {
            $state = 'listening'
        } else {
            $stxt = Read-BusText $StateFile
            $raw = if ($stxt) { $stxt.Trim().ToLower() } else { '' }
            # The state file is not always reset to idle when a turn ends, so
            # "speaking" with a stale waveform is treated as idle rather than
            # trusted - otherwise the board sits in a dim speaking pose forever.
            if ($raw -in @('idle','listening','thinking','speaking')) {
                $state = if ($raw -eq 'speaking') { 'idle' } else { $raw }
            }
        }
        $alert = Test-Path $AlertFile
    } catch {
        # NEVER silent. The first version of this script swallowed poll errors
        # and looked perfectly healthy while rendering nothing at all.
        $pollErrs++
        if ($pollErrs -le 5 -or $pollErrs % 300 -eq 0) { Log "bus read error #${pollErrs}: $($_.Exception.Message)" }
    }

    # Attack is fast so syllables punch. Decay is split deliberately: while
    # voice is still live it decays at 0.10 so the bloom tracks speech rhythm,
    # but once speech STOPS it decays at 0.045 - about 2.5 s to fall away
    # instead of 1 s. Brian asked for a longer release (2026-08-01); slowing
    # the decay globally would have smeared the bloom between syllables.
    $decay = if ($ttsLive) { 0.10 } else { 0.045 }
    if ($target -gt $level) { $level = $level + ($target - $level) * 0.60 }
    else                    { $level = $level + ($target - $level) * $decay }
    if ($level -gt $peakSeen) { $peakSeen = $level }

    # Slower follower, used ONLY for the bloom's width. Lagging both directions
    # is the point: it is what makes brightness lead width and gives the red
    # its breathe. Do not "simplify" this back to a single envelope.
    if ($level -gt $levelWide) { $levelWide = $levelWide + ($level - $levelWide) * 0.18 }
    else                       { $levelWide = $levelWide + ($level - $levelWide) * 0.055 }

    # Once speech stops the waveform goes stale and $target drops to 0, but
    # $level keeps decaying at 0.10/frame - roughly a second to fall away. Keep
    # rendering the RED bloom for that decay instead of cutting to idle, so the
    # colour dims and narrows out rather than vanishing. Bounded by $ReleaseSec
    # so a wedged bus can never leave the board stuck red.
    # !! $ttsLive, not $waveLive - Brian talking must never start or extend
    # Jarvis's red release tail.
    if ($ttsLive) { $lastSpeakAt = Get-Date }
    $releasing = (-not $ttsLive) -and ($level -gt $ReleaseFloor) -and (((Get-Date) - $lastSpeakAt).TotalSeconds -lt $ReleaseSec)

    $phase += 0.05
    if ($phase -gt [Math]::PI * 2) { $phase -= [Math]::PI * 2 }
    $breath = (([Math]::Sin($phase) + 1) / 2)

    # Speaking is RED (Brian's call, 2026-08-01). Alert is also red, but it
    # renders as a flat full-board pulse rather than a centred bloom, so the
    # two still read differently at a glance.
    # Cross-fade weight for the idle blue: 0 while voice is live, rising to 1
    # over $CrossSec once it stops. Brian, 2026-08-01: the blue must come up
    # WHILE the red is still draining, so the two overlap and the hand-off is
    # seamless - not red-out-then-blue-in as a sequence. Note this same weight
    # also drives the idle branch, so there is exactly ONE ramp and the blue
    # never drops back to zero when the release finally gives up.
    $xfade = if ($ttsLive) { 0.0 } else { [Math]::Min(1.0, ((Get-Date) - $lastSpeakAt).TotalSeconds / $CrossSec) }
    $idleAmp = 0.28 + 0.18 * $breath

    # ---- music bus ----------------------------------------------------
    # Read at the frame rate; it is one small local file, same as the voice bus.
    # !! TTS WINS. Jarvis speaking must always look like Jarvis speaking, and
    # his own voice is on those speakers too - without this the lights would
    # "react to the music" of his own reply.
    $musicOn = $false; $mLevel = 0.0; $mBass = 0.0; $mMid = 0.0; $mTreb = 0.0; $mBeat = $false
    # !! MUSIC ONLY DRIVES THE LIGHTS WHEN JARVIS IS IDLE. Any real state -
    # speaking, thinking, listening - wins outright.
    #
    # The first version excluded only TTS, releasing and listening, and Brian
    # immediately hit the hole: "the thinking light... goes yellow and it blinks
    # like with a strobe and white." JARVIS'S OWN THINKING SOUND comes out of
    # the same speakers, the analyser hears it and reports music, and music mode
    # took the lights over during the exact moment the amber wave should show.
    # The wave itself was never broken - a frame dump proved it rendering pure
    # yellow and travelling correctly. It was simply never reached.
    #
    # The general rule this encodes: an AMBIENT effect must never outrank a
    # STATUS indicator. Music is ambience; thinking/speaking/listening tell him
    # what Jarvis is actually doing.
    $musicOff = (Test-Path $MusicOffFlag)
    if (-not $NoMusic -and -not $musicOff -and -not $ttsLive -and -not $releasing -and $state -eq 'idle') {
        try {
            $mtxt = Read-BusText $MusicBus
            if ($mtxt) {
                $mb = $mtxt | ConvertFrom-Json
                if (((Get-UnixNow) - [double]$mb.ts) -lt $MusicFreshSec -and $mb.playing) {
                    $musicOn = $true
                    $mLevel = [double]$mb.level; $mBass = [double]$mb.bass
                    $mMid   = [double]$mb.mid;   $mTreb = [double]$mb.treble
                    $mBeat  = [bool]$mb.beat
                    $mHue   = [int]$mb.hue
                    if ($mBeat) { $script:beatFlash = 1.0 }
                }
            }
        } catch { $script:musicErrs++ }
    }

    # ---- screen bus -----------------------------------------------------
    # Same gate as music, for the same reason: an AMBIENT effect must never
    # outrank a STATUS indicator. Read AFTER music so it can take the wheel from
    # it - screen is what Brian asked for, and he plays on headphones anyway.
    #
    # !! $screenOn DELIBERATELY CLEARS $musicOn. Both feed the same 'music'
    # branch below, so leaving both set would mean the spectral hue and the
    # screen colour fighting over $bR/$bG/$bB depending on branch order. One
    # owner per frame.
    $screenOn = $false; $sR = 0.0; $sG = 0.0; $sB = 0.0; $sLevel = 0.0
    $sC1 = 0.0; $sC2 = 0.0; $sC3 = 0.0
    # Spatial colours. $scrCols runs left-to-right across the monitor and is what
    # lets a light on Brian's left show what is on the left of his screen.
    $scrL = $null; $scrR = $null; $scrCols = $null
    $screenOff = (Test-Path $ScreenOffFlag)
    if (-not $NoScreen -and -not $screenOff -and -not $ttsLive -and -not $releasing -and $state -eq 'idle') {
        try {
            $stxt2 = Read-BusText $ScreenBus
            if ($stxt2) {
                # !! THIS OBJECT IS NAMED $scr, NOT $sb, AND THAT IS NOT STYLE.
                # PowerShell variable names are CASE-INSENSITIVE, so $sb (the
                # parsed payload) and $sB (the blue channel) are the SAME
                # VARIABLE. The first build used both: assigning blue silently
                # overwrote the whole parsed object with a double, and every
                # field read AFTER that line came back $null -> 0.
                #
                # It failed in the nastiest possible shape: red and green were
                # assigned before the collision so they were correct, and only
                # level, the three columns and the flash were dead. A harness
                # caught it before it ever ran on the lights. Do not rename this
                # back to something that collides with $sR/$sG/$sB.
                $scr = $stxt2 | ConvertFrom-Json
                if (((Get-UnixNow) - [double]$scr.ts) -lt $ScreenFreshSec -and $scr.active) {
                    $screenOn = $true
                    $musicOn  = $false
                    $sR = [double]$scr.r; $sG = [double]$scr.g; $sB = [double]$scr.b
                    $sLevel = [double]$scr.level
                    $sC1 = [double]$scr.c1; $sC2 = [double]$scr.c2; $sC3 = [double]$scr.c3
                    $scrL = @([double]$scr.lr, [double]$scr.lg, [double]$scr.lb)
                    $scrR = @([double]$scr.rr, [double]$scr.rg, [double]$scr.rb)
                    # An older capture that predates columns simply leaves this
                    # $null and every lamp falls back to the whole-screen colour.
                    if ($scr.PSObject.Properties.Name -contains 'cols' -and $scr.cols) {
                        $scrCols = @($scr.cols)
                    }
                    # A flash on screen reuses the beat flash variable, because
                    # Get-StripFrame's 'music' mode already reads it - the strip
                    # punches with no change to that function.
                    #
                    # !! SCALED BY MAGNITUDE, and MAX rather than assignment. The
                    # capture publishes how big the jump was, so a grenade and a
                    # muzzle flare do not land identically; MAX stops a small
                    # flash arriving mid-decay from cutting a big one short.
                    if ([bool]$scr.flash) {
                        $sFlashMag = [double]$scr.flash_mag
                        # An older capture that sends no magnitude still works.
                        if ($sFlashMag -le 0) { $sFlashMag = 0.6 }
                        if ($sFlashMag -gt $script:beatFlash) { $script:beatFlash = $sFlashMag }
                    }
                }
            }
        } catch { $script:musicErrs++ }
    }

    # Beat flash decays across frames rather than lasting one frame - a single
    # 33 ms frame is invisible on hardware that only redraws a few times a second.
    # !! 0.09 IS THE ACCEPTED VALUE - do not "add more strobe" again.
    # A harder, faster flash was tried on 2026-08-02 (decay 0.22, brightness
    # term 0.85, saturation term 0.45) at Brian's request for "more strobe".
    # He looked at it and reverted the lot: "that doesn't do anything I wanted
    # to do." The softer swell is what he likes. Revisit only if he raises it.
    #
    # !! THE 0.09 ABOVE IS THE MUSIC VALUE AND IT IS UNTOUCHED. Screen mode
    # decays faster, because gunfire is a fast train of hits and a slow decay
    # smears them into one continuous glow - which is a large part of why Brian
    # called the first build "so subtle nobody noticed it". Music keeps exactly
    # the look he accepted; only the screen path is quicker.
    $flashDecay = if ($screenOn) { 0.17 } else { 0.09 }
    if ($script:beatFlash -gt 0) { $script:beatFlash = [Math]::Max(0, $script:beatFlash - $flashDecay) }

    $ampWidth = -1   # -1 = "track brightness"; only the speaking bloom overrides it
    $blueAmp  = 0.0  # idle blue mixed in UNDERNEATH the active layer
    if ($alert)                    { $bR=1.0; $bG=0.02; $bB=0.02; $mode='flat';  $amp = 0.55 + 0.45*$breath }
    elseif ($screenOn) {
        # THE COLOUR IS THE SCREEN'S. No palette, no hue drift, no random
        # jumping - all of which the music mode does deliberately and none of
        # which belongs here. If the room does not match what is on the monitor,
        # this effect has failed at the one thing it was asked to do.
        #
        # The capture side already boosted saturation and lifted the value
        # curve; a raw frame average is a muddy grey-brown and reads as "the
        # lights are just dim white". Nothing further is done to the hue here.
        $bR = $sR; $bG = $sG; $bB = $sB
        # !! FLOOR DROPPED 0.18 -> 0.09 AND THE CURVE STEEPENED 1.30 -> 1.60, on
        # Brian's verdict that the effect was too subtle. A high floor with a
        # shallow slope compresses everything into the middle, and a room that
        # never goes dark has nowhere to go bright FROM - the contrast is what
        # gets noticed, not the average level.
        #
        # It is a floor rather than zero on purpose: full black on a lamp is
        # indistinguishable from the lighting having died, and this project has
        # been bitten by silent-failure lighting more than once.
        # !! 0.02 + 1.30, DOWN FROM 0.05 + 1.60. The aggressive pass made a dim
        # scene drive the lamps at half brightness, which stops being "following
        # the screen" and starts being a light show that ignores it. Brightness
        # is meant to track the monitor, not flatter it.
        # !! CEILING 0.80, GAIN 1.30 -> 1.00. Brian: "it's just bright as fuck."
        # Full-value colour times a boosted amp was flooding the room, and a
        # room at full white has no colour left to read - which is why brighter
        # kept making it look LESS like the screen, not more.
        $amp = [Math]::Max(0.05, [Math]::Min(0.80, 0.02 + $sLevel * 1.00))
        # Shared with the per-lamp zone colours further down, so a flash punches
        # every light rather than only the ones fed from $bR/$bG/$bB.
        $sFlashWht = 0.0
        if ($script:beatFlash -gt 0) {
            # !! HARDER THAN THE MUSIC PUNCH (0.55), and it blows out toward
            # WHITE as well as up. A flash that only raises brightness reads as
            # "the lamp got brighter"; one that also desaturates reads as a
            # flash of light in the room, which is what gunfire actually is.
            # Scaled by magnitude at the source, so this is not a constant strobe.
            # Deliberately allowed past the 0.80 amp ceiling - the ceiling is the
            # resting level, and a flash is supposed to exceed it.
            $amp = [Math]::Min(1.0, $amp + 0.95 * $script:beatFlash)
            $sFlashWht = 0.60 * $script:beatFlash
            $bR = $bR + (1.0 - $bR) * $sFlashWht
            $bG = $bG + (1.0 - $bG) * $sFlashWht
            $bB = $bB + (1.0 - $bB) * $sFlashWht
        }
        # Feed the three screen COLUMNS into the same script-scope slots the
        # strip's travelling effect already reads, so the strip maps
        # left-to-right across the monitor instead of pulsing flat.
        # !! The names still say bass/mid/treble because Get-StripFrame reads
        # those exact variables. Renaming them would mean touching that function
        # and every other writer of them for no behavioural gain.
        $script:mBassV = $sC1; $script:mMidV = $sC2; $script:mTrebV = $sC3
        $mode     = 'flat'
        $ampWidth = -1
        # !! 'screen', NOT 'music', AND THE DIFFERENCE IS THE WHOLE FEATURE.
        #
        # Reusing 'music' looked free - every surface already had a music case,
        # so nothing downstream needed touching. It was wrong, and it wasted a
        # long session because the failure was invisible from every angle I was
        # looking at: the bus was right, the render loop reported screen=ON, and
        # the log printed the correct screen colour every ten seconds.
        #
        # What actually happened is that 'music' is not a COLOUR on the lamps and
        # the strip - it is a SPECTRUM VISUALISER. Those surfaces route music
        # into Get-BlendedFrame/Get-StripFrame, which compute a hue PER PIXEL
        # from $script:musicHue - a palette that drifts on its own and jumps on
        # beats. The comment at the Govee wave branch says so in as many words.
        # So $bR/$bG/$bB, the screen's real colour, was computed, logged, and
        # then thrown away before it ever reached the four lamps Brian looks at.
        #
        # Brian: "it doesn't do a very good job at all man." He was right, and no
        # amount of tuning the colour could have helped - the colour was not the
        # thing being displayed.
        #
        # 'screen' takes the FLAT path on every surface: it is deliberately
        # absent from every ($state -eq 'thinking' -or $state -eq 'music') wave
        # test, and paired with 'music' only where that branch renders a flat
        # $bR/$bG/$bB * $amp. If a new surface is added, give it a 'screen' case
        # in its FLAT branch, never in its wave branch.
        $state    = 'screen'
    }
    elseif ($musicOn) {
        # Simple beat pulse mode: random color from analyser, lights stay on, brighten on beat
        $script:musicHue = $mHue
        $c = Convert-HsvToRgb $script:musicHue 1.0 1.0
        $bR = $c[0]; $bG = $c[1]; $bB = $c[2]
        $mode     = 'music'
        $amp      = [Math]::Min(1.0, 0.15 + 0.85 * $script:beatFlash)
        $ampWidth = -1
        # !! THIS LINE IS LOAD-BEARING AND WAS MISSING ON THE FIRST BUILD.
        # Every surface picks its colour from $state, not from $bR/$bG/$bB - so
        # with $state still 'idle' the detection worked perfectly (the heartbeat
        # even said music=ON) while every flat surface rendered idle blue.
        # Brian saw exactly that: "it doesn't switch to the music."
        # Setting the state is what lets the per-surface colour chains below
        # know music is driving. They all need a 'music' case; see them.
        $state    = 'music'
    }
    elseif ($state -eq 'speaking' -or $releasing) { $bR=1.0; $bG=0.04; $bB=0.00; $mode='bloom'; $amp = [Math]::Min(1.0, $level * $Gain); $ampWidth = [Math]::Min(1.0, $levelWide * $Gain); $blueAmp = $idleAmp * $xfade }
    elseif ($state -eq 'thinking') { $bR=1.0; $bG=0.45; $bB=0.02; $mode='scan';  $amp = 1.00 }
    elseif ($state -eq 'listening'){ $bR=0.05; $bG=1.0; $bB=0.30;  $mode='flat';  $amp = 0.60 + 0.35*$breath }
    else {
        # Idle. Uses the SAME $xfade the release used, so when the red finally
        # gives up the blue is already at exactly the level it had reached
        # underneath it - the switch of layers is invisible.
        $bR=0.10; $bG=0.30; $bB=0.90; $mode='flat'
        $amp = $idleAmp * $xfade
    }

    # --- recovery.
    #
    # Driven by a FLAG, not by a send failure. The obvious design - "re-discover
    # when a send fails" - has a hole that bit on 2026-08-01: if re-discovery
    # runs while OpenRGB is still restarting it connects fine but finds ZERO
    # devices, and with no devices there are no sends left to fail, so nothing
    # ever triggers another attempt. The loop spins forever painting nothing,
    # with a completely clean log. It stays flagged until it genuinely has
    # hardware again. The boot task bounces the OpenRGB service on every
    # startup, so this path runs for real, not just in theory.
    if ($needsDiscovery -and (Get-Date) -ge $nextDiscoveryAt) {
        try {
            try { Disconnect-Orgb $conn } catch { }
            $conn = Connect-Orgb -ClientName 'Jarvis Voice Lights'
            $set = Get-DeviceSet $conn $DeviceMatch
            $keyboard = $set.Keyboard
            $ramParts = $set.RamParts
            $ramTotal = $set.RamTotal
            # Re-declared on every re-discovery, not just at startup: an OpenRGB
            # restart resets every addressable channel back to 0 LEDs.
            $fans     = $set.Fans
            $aura     = $set.Aura
            $gpu      = $set.Gpu
            if (-not $keyboard -and $ramParts.Count -eq 0) { throw 'connected, but OpenRGB reports no devices yet' }
            foreach ($d in @($keyboard) + $ramParts + @($fans) + @($aura) + @($gpu)) { if ($d) { try { Set-OrgbCustomMode $conn $d.Idx } catch { } } }
            Log "re-discovered after $discoveryTries failed attempt(s): keyboard=$(if($keyboard){$keyboard.Idx}else{'none'}) ramParts=$($ramParts.Count) ramLeds=$ramTotal fans=$(if($fans){$fans.Leds}else{'none'}) aura=$(if($aura){$aura.Leds}else{'none'}) gpu=$(if($gpu){'yes'}else{'none'})"
            $needsDiscovery = $false
            $discoveryTries = 0
        } catch {
            $discoveryTries++
            if ($discoveryTries -le 3 -or $discoveryTries % 20 -eq 0) {
                Log "re-discovery attempt ${discoveryTries} failed: $($_.Exception.Message)"
            }
            $nextDiscoveryAt = (Get-Date).AddSeconds(3)
        }
    }

    $sendFailed = $false

    # Shared syllable envelope for the flat surfaces. Driven by the RAW
    # per-frame level, not the smoothed $amp, so it tracks syllables rather
    # than staying up across a whole sentence.
    $ftgt = 0.0
    if ($ttsLive) { $ftgt = [Math]::Min(1.0, $target * $Gain) }
    if ($ftgt -gt $voiceEnv) { $voiceEnv = $voiceEnv + ($ftgt - $voiceEnv) * $FlatAttack }
    else                     { $voiceEnv = $voiceEnv + ($ftgt - $voiceEnv) * $FlatDecay }
    if ($voiceEnv -lt 0.004) { $voiceEnv = 0.0 }
    # Fold into the GPU's peak-hold. Done here, at the full 30 fps, so no
    # syllable is missed between that surface's much slower writes.
    if ($voiceEnv -gt $script:gpuPeakEnv) { $script:gpuPeakEnv = $voiceEnv }
    $flatRgb = Get-FlatColor

    # --- keyboard: one flat colour across all 104 keys (replaced the bloom
    # on Brian's explicit call, 2026-08-01)
    if ($keyboard) {
        # ⭐ One exception to the flat colour, on Brian's request 2026-08-01: he
        # missed the amber WAVE sweeping across the keys while thinking, so the
        # keyboard still renders the original 'scan' mode for that one state.
        # Every other state stays flat. The scan code was never removed - the
        # loop still sets $mode='scan' for thinking - it had just stopped being
        # called when the bloom was replaced.
        if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) {
            $kb = Get-BlendedFrame $keyboard.Leds
        } else {
            $kb = Get-FlatFrame $keyboard.Leds $flatRgb
        }
        try { Send-Frame $conn $keyboard.Idx $kb $keyboard.Leds; $frames++ }
        catch { $sendFailed = $true }
    }

    # --- RAM: paint ONE virtual strip spanning every stick, then slice it
    # per controller. This is what makes the bloom travel across the sticks
    # as a group instead of every stick pulsing identically in place.
    # Every stick takes the same flat colour now, so the slot ordering that the
    # bloom needed no longer affects appearance - it is kept because the RAM
    # rescue and boot task still depend on it, and because reverting to a
    # travelling effect would need it again.
    if ($ramParts.Count -gt 0) {
        # While thinking, the sticks become ONE virtual strip again so the amber
        # wave travels across the whole row - which is why the physical slot
        # ordering still matters. Punch is skipped for the wave deliberately:
        # it normalises each LED to full saturation, which would flatten the
        # very brightness gradient the wave is made of.
        $ramWave = $null
        if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) { $ramWave = Get-BlendedFrame $ramTotal }
        foreach ($p in $ramParts) {
            if ($ramWave) {
                $slice = New-Object byte[] ($p.Leds * 4)
                [Array]::Copy($ramWave, $p.Offset * 4, $slice, 0, $p.Leds * 4)
            } else {
                $slice = Get-FlatFrame $p.Leds $flatRgb
                Convert-ToPunch $slice $p.Leds $RamFloor $RamSpan $RamGamma
            }
            try { Send-Frame $conn $p.Idx $slice $p.Leds }
            catch { $sendFailed = $true }
        }
        $frames++
    }

    if ($sendFailed -and -not $needsDiscovery) {
        Log 'frame send failed - flagging for re-discovery'
        $needsDiscovery  = $true
        $nextDiscoveryAt = (Get-Date).AddSeconds(2)
    }

    # --- extras: radiator fans, the motherboard's addressable header, the GPU.
    #
    # Wrapped whole and on its own failure counter, deliberately: these must
    # never set $sendFailed. If OpenRGB genuinely dies the keyboard and RAM
    # sends fail on their own and trigger re-discovery correctly; an extras-only
    # failure means one surface is missing, not that the board should go dark.
    if (-not $NoExtras -and $extrasFrameMs -gt 0 -and
        ((Get-Date) - $lastExtrasAt).TotalMilliseconds -ge $extrasFrameMs) {
        try {
            # Fans: one bloom repeated per Riing channel, because which channels
            # actually have fans on them is unknown - a single continuous bloom
            # would leave a populated channel dark whenever its centre sat on an
            # empty one.
            if ($fans) {
                if ($FanStyle -eq 'trio') {
                    # A 3-element render of the same bloom: element 0 and 2 are
                    # the white edges, element 1 is the red core. Each whole fan
                    # takes one element, so the three fans differ from each
                    # other rather than each showing an invisible gradient.
                    if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) {
                        # Thinking: an explicit LEFT -> CENTRE -> RIGHT march.
                        #
                        # This used to be Get-BlendedFrame 3 - the shared bloom
                        # rendered onto three points - and Brian could not read a
                        # direction in it. Same root cause as the mouse before it
                        # became a pulse: Get-StripFrame scales the bloom's width
                        # PROPORTIONALLY to strip length, which is correct at 104
                        # keys and turns to mush at 3. Anything this short needs
                        # its position computed directly, never a squeezed bloom.
                        #
                        # Driven off the SAME $phase as every other surface, so
                        # the fans stay in step with the wave crossing the
                        # keyboard, RAM, strip and mouse rather than running to
                        # their own clock. Brian asked for one wave across
                        # everything; this keeps that true.
                        # KNIGHT RIDER. Brian, 2026-08-01: "do it like Knight
                        # Rider, from left to right, just red, back and forth
                        # like Knight Rider's car - and as bright as you can,
                        # when you're thinking only."
                        #
                        # RED, not the amber every other surface uses in this
                        # state - deliberate, and the one place the rig breaks
                        # colour agreement on purpose. It is a scanner, not a
                        # wave.
                        #
                        # BOUNCES rather than wrapping: a triangle wave off
                        # $phase drives the position 0 -> 2 -> 0, so the spot
                        # reverses at each end the way KITT's does. A wrapping
                        # march would teleport back to the left every cycle.
                        # DISCRETE, one fan at a time. Brian, after seeing the
                        # smooth version: "you need to make it from one fan to
                        # the next fan to the next fan, then back... left fan to
                        # the middle fan to the right fan, from the right fan to
                        # the middle fan to the left fan."
                        #
                        # The first attempt used a distance falloff, which
                        # cross-fades - at any moment two fans were part-lit and
                        # the movement was unreadable. With only THREE positions
                        # there is no room for a gradient; a scanner this short
                        # has to STEP. Four equal steps, left / centre / right /
                        # centre, so the bounce spends the same time on each fan
                        # and reverses cleanly at the ends.
                        # ⭐ REVERTED here on Brian's call - "go back to what you
                        # had and just make it back and forth faster."
                        #
                        # A per-LED version was built next, treating the three
                        # fans as one 90-LED strip so the line swept ACROSS each
                        # fan as well as between them. He asked for it, saw it,
                        # and sent it back. Do not rebuild it without him asking
                        # again: at 15 fan updates a second there are only a
                        # couple of frames per sweep, so the extra resolution
                        # cannot actually be rendered - it reads worse, not
                        # better, than clean whole-fan steps.
                        #
                        # Four equal steps, left / centre / right / centre, so the
                        # bounce dwells evenly on each fan and reverses at the
                        # ends rather than teleporting back to the left.
                        $u = (($phase / ([Math]::PI * 2)) * $FanScanSpeed)
                        $u = $u - [Math]::Floor($u)
                        $stepIdx = [int][Math]::Floor($u * 4.0)
                        if ($stepIdx -gt 3) { $stepIdx = 3 }
                        $order = @(0, 1, 2, 1)
                        $lit = $order[$stepIdx]
                        # The head snaps to one fan; every OTHER fan decays from
                        # whatever it was, which is the trail. Decay over TIME,
                        # not distance - a spatial falloff was tried and rejected
                        # because with three positions it just leaves two fans
                        # permanently half-lit.
                        for ($k = 0; $k -lt 3; $k++) {
                            if ($k -eq $lit) {
                                $script:fanScanLv[$k] = 1.0
                            } else {
                                $script:fanScanLv[$k] = $script:fanScanLv[$k] * $FanScanDecay
                                # Hard cutoff. Without it the tail never reaches
                                # zero, because the fan curve's own 0.08 floor
                                # lifts any non-zero value back to a visible ~20.
                                if ($script:fanScanLv[$k] -lt 0.02) { $script:fanScanLv[$k] = 0.0 }
                            }
                        }
                        $three = New-Object byte[] 12
                        for ($k = 0; $k -lt 3; $k++) {
                            $three[$k * 4]     = [byte][int][Math]::Round(255 * $script:fanScanLv[$k])
                            $three[$k * 4 + 1] = 0
                            $three[$k * 4 + 2] = 0
                        }
                    } else {
                        # ⚠ A "MOUTH" was built here and REJECTED by Brian on
                        # sight (2026-08-01) - an all-red opening that grew from
                        # the centre fan outward to the left and right with voice
                        # level, rendered per-LED across all 90. His words: "yeah,
                        # that doesn't look good, we're gonna have to go back the
                        # other way." Do not rebuild it unprompted. The speaking
                        # look is the red-core / white-edge trio below, which is
                        # the last place the original bloom survives.
                        $fc = Get-FanColors
                        $three = New-Object byte[] 12
                        for ($k = 0; $k -lt 3; $k++) {
                            $three[$k]     = $fc.Outer[$k]    # element 0 = outer fans
                            $three[4 + $k] = $fc.Centre[$k]   # element 1 = centre fan
                            $three[8 + $k] = $fc.Outer[$k]    # element 2 = outer fans
                        }
                    }
                    $chMap = @{}
                    $chMap[($FanCentreChannel - 1)] = 1
                    $chMap[($FanLeftChannel   - 1)] = 0
                    $chMap[($FanRightChannel  - 1)] = 2
                    $ff = New-Object byte[] ($fans.Leds * 4)
                    for ($ch = 0; $ch -lt $fans.Channels; $ch++) {
                        # Any channel not mapped to a fan (4 and 5 here) takes
                        # the edge colour, so it turns white with the outers.
                        $el = 0
                        if ($chMap.ContainsKey($ch)) { $el = $chMap[$ch] }
                        $s = $el * 4
                        for ($i = 0; $i -lt $fans.PerChannel; $i++) {
                            $o = (($ch * $fans.PerChannel) + $i) * 4
                            if ($o + 2 -ge $ff.Length) { break }
                            $ff[$o] = $three[$s]; $ff[$o+1] = $three[$s+1]; $ff[$o+2] = $three[$s+2]
                        }
                    }
                } elseif ($FanStyle -eq 'pulse') {
                    # Whole ring, one colour, taken from the peak of the same
                    # bloom the keyboard is showing - so the shade matches
                    # exactly rather than being a separately-computed colour.
                    $pk = Get-PeakColor
                    $ff = New-Object byte[] ($fans.Leds * 4)
                    for ($i = 0; $i -lt $fans.Leds; $i++) { $o = $i * 4; $ff[$o] = $pk[0]; $ff[$o+1] = $pk[1]; $ff[$o+2] = $pk[2] }
                } else {
                    $ff = Get-ChannelFrame $fans.Channels $fans.PerChannel 0 -Reverse $FanReverse -Gain $FanGain
                }
                # Saturate-then-dim, applied last so it covers every fan style.
                # Per LED: scale the triple so its brightest channel reaches
                # 255 (full saturation, hue untouched), then re-apply brightness
                # with a floor. Never multiply all three channels to "brighten"
                # - that only whitens; this is the operation that actually adds
                # punch without touching the colour.
                # IDLE gets its own, much brighter curve. Brian, 2026-08-01: "make
                # the fans when they're at idle blue as bright of a blue as you
                # can - not bright like LIGHT blue, but bright like the actual
                # lumen, make it brighter."
                #
                # The distinction matters and drives the implementation. Making it
                # "lighter" would mean adding green and red, which desaturates to
                # pale blue - the exact mistake made earlier with fan gain. This
                # instead leaves the hue at pure 0,0,255 and lifts only the
                # brightness the curve applies. Idle was landing near 55/255,
                # because the shared 0.08 floor and 1.8 gamma are tuned to keep
                # the SPEAKING range punchy and they crush a gentle idle breathe.
                #
                # Applies only when genuinely idle - not during the release tail,
                # or the red would come back up at full brightness on every pause.
                $curveFloor = $FanFloor; $curveSpan = $FanSpan; $curveGamma = $FanGamma
                if ($state -ne 'speaking' -and $state -ne 'thinking' -and $state -ne 'listening' -and -not $alert -and -not $releasing) {
                    $curveFloor = $FanIdleFloor; $curveSpan = $FanIdleSpan; $curveGamma = $FanIdleGamma
                }
                $g = @($FanRedGain, $FanGreenGain, $FanBlueGain)
                for ($i = 0; $i -lt $fans.Leds; $i++) {
                    $o = $i * 4
                    $r = [double]$ff[$o] * $g[0]; $gr = [double]$ff[$o+1] * $g[1]; $b = [double]$ff[$o+2] * $g[2]
                    $max = [Math]::Max($r, [Math]::Max($gr, $b))
                    if ($max -lt 1) { $ff[$o]=0; $ff[$o+1]=0; $ff[$o+2]=0; continue }
                    # How bright this LED was meant to be, 0..1.
                    $t = [Math]::Min(1.0, $max / 255.0)
                    if ($curveGamma -ne 1.0) { $t = [Math]::Pow($t, $curveGamma) }
                    $bright = $curveFloor + $curveSpan * $t
                    $k = (255.0 / $max) * $bright
                    $vr = [int][Math]::Round($r * $k);  if ($vr -gt 255) { $vr = 255 }
                    $vg = [int][Math]::Round($gr * $k); if ($vg -gt 255) { $vg = 255 }
                    $vb = [int][Math]::Round($b * $k);  if ($vb -gt 255) { $vb = 255 }
                    $ff[$o] = [byte]$vr; $ff[$o+1] = [byte]$vg; $ff[$o+2] = [byte]$vb
                }
                Send-Frame $conn $fans.Idx $ff $fans.Leds
            }
            # Aura: the 2 onboard LEDs take the bloom's peak colour (too few to
            # show a gradient), then one bloom per addressable channel.
            if ($aura -and $AuraStyle -eq 'fade') {
                # Syllable-driven red with soft edges. Target comes from the RAW
                # per-frame waveform (not the smoothed $amp, which holds up
                # across a whole sentence), then its own attack/decay envelope
                # smooths the switching so it fades toward dark rather than
                # snapping - which is what made the hard gate look choppy.
                $tgt = 0.0
                if ($ttsLive) { $tgt = [Math]::Min(1.0, $target * $Gain) }
                if ($tgt -gt $auraEnv) { $auraEnv = $auraEnv + ($tgt - $auraEnv) * $AuraAttack }
                else                   { $auraEnv = $auraEnv + ($tgt - $auraEnv) * $AuraDecay }
                if ($auraEnv -lt 0.004) { $auraEnv = 0.0 }

                # STATE layer - the strip must still show every other state, not
                # just speech. The first version of this only drew the red and
                # left idle, thinking and listening black; Brian caught it
                # immediately ("you turned off the yellow for thinking, you
                # turned off the blue for idle").
                $fr = 0.0; $fg = 0.0; $fb = 0.0
                if ($alert)                       { $fr = $amp }
                elseif ($state -eq 'music' -or $state -eq 'screen') { $fr = $amp * $bR; $fg = $amp * $bG; $fb = $amp * $bB }
                elseif ($state -eq 'thinking')    { $fr = $amp; $fg = $amp * 0.51 }   # amber
                elseif ($state -eq 'listening')   { $fg = $amp; $fb = $amp * 0.35 }   # green
                elseif ($state -eq 'speaking' -or $releasing) { $fb = $blueAmp }      # blue rises on the release tail
                else                              { $fb = $amp }                      # idle blue

                # SYLLABLE layer on top, unchanged. Taking the max rather than
                # adding keeps the red pure instead of tinting it toward the
                # state colour underneath.
                if ($ttsLive) { $fr = [Math]::Max($fr, $auraEnv) }

                $af = New-Object byte[] ($aura.Leds * 4)
                if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) {
                    # Thinking: the amber wave sweeps along the strip's length,
                    # repeated identically on each addressable channel.
                    $wv = Get-BlendedFrame $aura.PerChannel
                    for ($ch = 0; $ch -lt $aura.Channels; $ch++) {
                        [Array]::Copy($wv, 0, $af, ($aura.Header + $ch * $aura.PerChannel) * 4, $wv.Length)
                    }
                    if ($aura.Header -gt 0) {
                        $pk = Get-PeakColor
                        for ($i = 0; $i -lt $aura.Header; $i++) { $o = $i * 4; $af[$o] = $pk[0]; $af[$o+1] = $pk[1]; $af[$o+2] = $pk[2] }
                    }
                } else {
                    $vr = [int][Math]::Round(255 * $fr); if ($vr -gt 255) { $vr = 255 }
                    $vg = [int][Math]::Round(255 * $fg); if ($vg -gt 255) { $vg = 255 }
                    $vb = [int][Math]::Round(255 * $fb); if ($vb -gt 255) { $vb = 255 }
                    for ($i = 0; $i -lt $aura.Leds; $i++) {
                        $o = $i * 4
                        $af[$o] = [byte]$vr; $af[$o+1] = [byte]$vg; $af[$o+2] = [byte]$vb
                    }
                }
                Send-Frame $conn $aura.Idx $af $aura.Leds
            }
            elseif ($aura -and $AuraStyle -eq 'gate') {
                # Hard binary: full red above the threshold, black below it.
                # No punch curve, no invert, no idle colour - deliberately.
                # ⚠ Gates on the RAW per-frame waveform reading, not on $amp.
                #
                # Brian, 2026-08-01: "as you're talking the red light flashes
                # with your syllables." $amp comes off the smoothed envelope
                # (fast attack but a 0.10/frame decay, ~a third of a second) and
                # $releasing holds it up for seconds afterwards - between them
                # the gate stayed on across a whole sentence. $target is the
                # instantaneous level for this frame, so it drops in the gaps
                # between syllables and the strip actually flashes with speech.
                # $ttsLive is required too, so the release tail cannot hold it on
                # - and, since 2026-08-02, so Brian's own microphone cannot
                # either.
                $inst = [Math]::Min(1.0, $target * $Gain)
                $on = $ttsLive -and ($inst -ge $AuraGateLevel)
                $af = New-Object byte[] ($aura.Leds * 4)
                if ($on) {
                    for ($i = 0; $i -lt $aura.Leds; $i++) { $o = $i * 4; $af[$o] = 255; $af[$o+1] = 0; $af[$o+2] = 0 }
                }
                Send-Frame $conn $aura.Idx $af $aura.Leds
            }
            elseif ($aura) {
                $one = Get-AuraStripFrame $aura.PerChannel
                $af = New-Object byte[] ($aura.Leds * 4)
                if ($aura.Header -gt 0) {
                    $pk = Get-PeakColor
                    for ($i = 0; $i -lt $aura.Header; $i++) { $o = $i * 4; $af[$o] = $pk[0]; $af[$o+1] = $pk[1]; $af[$o+2] = $pk[2] }
                }
                for ($ch = 0; $ch -lt $aura.Channels; $ch++) {
                    [Array]::Copy($one, 0, $af, ($aura.Header + $ch * $aura.PerChannel) * 4, $one.Length)
                }
                Convert-ToPunch $af $aura.Leds $ExtraFloor $ExtraSpan $ExtraGamma $AuraInvert
                Send-Frame $conn $aura.Idx $af $aura.Leds
            }
            # GPU: a single LED. It uses the FANS' pure palette and the same
            # saturate-then-dim treatment, not the shared bloom.
            #
            # Brian, 2026-08-01: "figure out why you can't see my graphics
            # card." It was never unreachable - checked live and it sits in
            # Direct mode accepting every write. The problem was the same one
            # the fans had: it was being fed the bloom's dim, green-tinted mix,
            # and one small LED showing dim mud reads as nothing at all. Small
            # single-LED surfaces need full saturation or they may as well be off.
            # ⚠ Its own pacing gate, INSIDE the extras block. The fans and the
            # strip keep running at $ExtrasFps; only this surface is throttled.
            if ($gpu -and ((Get-Date) - $script:gpuSendAt).TotalSeconds -ge (1.0 / $GpuFps)) {
                $script:gpuSendAt = Get-Date
                # Brian, 2026-08-01: "make the GPU do the same thing" as every
                # other surface. It used to build its own colour from the FANS'
                # palette - a separate effect that merely resembled the others and
                # drifted from them every time one was tuned. It now calls
                # Get-FlatColor, the EXACT function driving the keyboard, the RAM
                # and the mouse, so every state hue and the per-syllable red flash
                # come from one place and cannot diverge again.
                #
                # THINKING is the one case a single LED cannot do literally: the
                # amber wave is a travelling gradient and there is no length here
                # to spread it over. Rather than sit flat - which is what it did
                # before, and what Brian noticed - sample that same travelling
                # wave at a FIXED POINT IN SPACE (the middle of a 9-wide render)
                # so the card brightens and fades as the sweep passes, pulsing in
                # time with the wave crossing the other five surfaces.
                #
                # Deliberately NOT Get-PeakColor here: the peak of a travelling
                # wave is essentially constant, which is precisely why this
                # surface read as flat amber in the first place.
                if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) {
                    $gw   = Get-BlendedFrame 9
                    $gm   = 4 * 4
                    $gcol = @($gw[$gm], $gw[$gm+1], $gw[$gm+2])
                } else {
                    # Peak-hold, not the instantaneous envelope - see gpuPeakEnv.
                    $gcol = Get-FlatColor -EnvOverride $script:gpuPeakEnv
                }
                # Carry a fraction forward rather than resetting to zero, so each
                # flash decays into the next window instead of cutting dead. This
                # is what smooths the rhythm at 5 fps - NOT a higher frame rate.
                $script:gpuPeakEnv = $script:gpuPeakEnv * $GpuTail
                $gf = New-Object byte[] ($gpu.Leds * 4)
                for ($i = 0; $i -lt $gpu.Leds; $i++) {
                    $o = $i * 4
                    $gf[$o] = $gcol[0]; $gf[$o+1] = $gcol[1]; $gf[$o+2] = $gcol[2]
                }
                Convert-ToPunch $gf $gpu.Leds $GpuFloor $GpuSpan $GpuGamma
                # ⚠ A per-second GPUDIAG line used to sit here, logging the real
                # bytes leaving for this card alongside the state and envelopes.
                # Removed 2026-08-01 once the card was settled - it wrote ~1 line
                # a second and had the log at 900 KB.
                #
                # Worth rebuilding the same way if this surface ever misbehaves
                # again: it is what finally solved it, after two rounds of
                # confident reasoning were both wrong. Log what actually leaves
                # for the device, then read it back against what Brian sees.
                if ($GpuSwapRB) {
                    for ($i = 0; $i -lt $gpu.Leds; $i++) {
                        $o = $i * 4
                        $tmp = $gf[$o]; $gf[$o] = $gf[$o+2]; $gf[$o+2] = $tmp
                    }
                }
                Send-Frame $conn $gpu.Idx $gf $gpu.Leds
            }
            $lastExtrasAt = Get-Date
        } catch {
            $extrasFails++
            if ($extrasFails -le 3 -or $extrasFails % 300 -eq 0) {
                Log "extras: send failed #${extrasFails}: $($_.Exception.Message)"
            }
            $lastExtrasAt = Get-Date
        }
    }

    # --- ROOM LIGHTING: Govee over its LAN API, and/or ChromaLink. -----------
    #
    # ⚠ DORMANT BY DEFAULT AND THAT IS DELIBERATE. Nothing in this block runs
    # unless -UseChromaLink is passed or -GoveeIps has at least one address.
    # Written 2026-08-01 while Brian's floor lamp and table lamp were still in
    # transit, specifically so they can be driven the evening they arrive rather
    # than after another build session - and gated so that writing it could not
    # affect the six surfaces already working.
    #
    # To wake it up once the lamps are set up (LAN Control switched on per-device
    # in the Govee MOBILE app - it is off by default):
    #     -GoveeIps '192.168.86.x','192.168.86.y'   and/or   -UseChromaLink
    #
    # Own timing gate, own failure counter, wrapped whole, and placed AFTER the
    # OpenRGB sends - same failure-isolation rule as the mouse: a room light
    # going away must never darken the board.
    if ($UseChromaLink -or $GoveeIps.Count -gt 0) {
        if (((Get-Date) - $script:roomSendAt).TotalSeconds -ge (1.0 / $GoveeFps)) {
            $script:roomSendAt = Get-Date
            try {
                # ChromaLink is FIVE zones, so it gets a 5-wide render of the same
                # frame everything else shows - the identical trick the three fans
                # use. Coarse, but it is a real wave rather than a flat colour.
                if ($UseChromaLink) {
                    if (-not $chromaLink) {
                        if ((Get-Date) -ge $script:nextLinkTryAt) {
                            try { $chromaLink = Connect-ChromaLink; Log 'chromalink: session open' }
                            catch { $script:nextLinkTryAt = (Get-Date).AddSeconds(5) }
                        }
                    }
                    if ($chromaLink) {
                        $lz = $script:CHROMA_LINK_ZONES
                        if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) { $lf = Get-BlendedFrame $lz }
                        else {
                            $lf = New-Object byte[] ($lz * 4)
                            $lc = Get-FlatColor
                            for ($i = 0; $i -lt $lz; $i++) { $o = $i*4; $lf[$o]=$lc[0]; $lf[$o+1]=$lc[1]; $lf[$o+2]=$lc[2] }
                        }
                        Send-ChromaLinkStrip -Session $chromaLink -Strip $lf
                    }
                }

                # !! REWRITTEN 2026-08-02. This used to push ONE whole-device
                # colour, because the RGBIC segments were believed unreachable
                # over LAN. They are not - see the corrected header in govee.ps1.
                # A lamp is now a real strip and gets exactly what the ARGB strip
                # gets: the amber wave sweeping its length while thinking, and a
                # flat state colour with the red syllable layer maxed on top for
                # every other state. Deliberately NOT a special effect of its own.
                if ($GoveeIps.Count -gt 0) {
                    # Segment mode has to be ARMED, and re-armed periodically. The
                    # device drops it on its own and there is no way to ask whether
                    # it is still in it - devStatus says nothing about segments. One
                    # tiny packet every 10 s makes recovery automatic after a lamp
                    # reboots or drops off the wifi, instead of it silently going
                    # deaf until the render loop is restarted.
                    if ((Get-Date) -ge $script:goveeArmAt) {
                        foreach ($ip in $GoveeIps) { [void](Enable-GoveeSegments -Ip $ip) }
                        $script:goveeArmAt = (Get-Date).AddSeconds(10)
                    }

                    # Lamp breath: deeper swing than the shared one, his call.
                    $gBreath = $GoveeBreathFloor + $GoveeBreathSpan * $breath

                    # !! ONE FRAME PER SEGMENT COUNT, NOT ONE FRAME FOR ALL LAMPS.
                    # Brian's two lamps are 10 and 8 segments, and a wrong count
                    # fails differently on each model - the H6022 truncates
                    # silently, the H6076 rejects the frame and shows nothing.
                    # Frames are cached by count so two lamps of the same size
                    # still only render once per tick.
                    $gCache = @{}
                    foreach ($lamp in $script:GoveeLamps) {
                      $gN = [int]$lamp.Segments

                      # !! SCREEN MODE IS PER LAMP AND THEREFORE BYPASSES THE
                      # CACHE ENTIRELY. The cache is keyed by SEGMENT COUNT,
                      # which was right when every lamp showed the same colour
                      # and is exactly wrong now: both floor lamps are 8
                      # segments, so they would share one frame and left/right
                      # would come out identical - the spatial effect silently
                      # collapsing back into the thing it replaced.
                      #
                      # Brian's layout, his own words 2026-08-03: "the two lights
                      # are out in front of me kind of out towards my monitor...
                      # the table light is back behind me like behind the monitor
                      # shining off the wall... the strip is underneath me."
                      #
                      #   Table Lamp    -> BIAS LIGHT, whole-screen colour
                      #   Floor Lamp    -> left quarter of the screen
                      #   Floor Lamp 2  -> right quarter of the screen
                      #   LED Strip     -> left-to-right gradient across the frame
                      #
                      # ⚠ WHICH FLOOR LAMP IS PHYSICALLY LEFT IS A GUESS. Brian
                      # said "the two lights are out in front of me" without
                      # naming sides. If they are backwards, swap $scrL and $scrR
                      # in the two lines below and nothing else changes.
                      # EVERY LAMP GETS A GRADIENT ACROSS ITS OWN SLICE OF THE
                      # SCREEN. Brian: "we have all these different colors, 16
                      # million colors of light, you should be able to make it do
                      # something." Flooding a 10-segment lamp with one colour
                      # throws away nine tenths of what it can do; between them
                      # these four devices have 41 addressable segments.
                      #
                      #   Table Lamp (10) -> the WHOLE screen width. It sits behind
                      #                      the monitor bouncing off the wall, so
                      #                      it mirrors the screen most directly.
                      #   Floor Lamp  (8) -> the LEFT half, spread across it
                      #   Floor Lamp 2(8) -> the RIGHT half, spread across it
                      #   LED Strip  (15) -> the WHOLE width, under the desk
                      if ($state -eq 'screen') {
                          $lname = [string]$lamp.Name
                          $gflat = New-Object int[] ($gN * 3)
                          $nc = 0
                          if ($scrCols) { $nc = $scrCols.Count }
                          if ($nc -gt 0) {
                              # Which slice of the screen this lamp shows.
                              # ⚠ WHICH FLOOR LAMP IS PHYSICALLY LEFT IS A GUESS -
                              # Brian said only "the two lights are out in front of
                              # me". If they are backwards, swap these two ranges.
                              $c0 = 0; $c1 = $nc - 1
                              if ($lname -like '*Floor Lamp 2*') { $c0 = [int]($nc / 2); $c1 = $nc - 1 }
                              elseif ($lname -like '*Floor Lamp*') { $c0 = 0; $c1 = [int]($nc / 2) - 1 }
                              if ($c1 -lt $c0) { $c1 = $c0 }
                              $span = $c1 - $c0
                              for ($i = 0; $i -lt $gN; $i++) {
                                  $f = 0.0
                                  if ($gN -gt 1) { $f = $i / [double]($gN - 1) }
                                  $ci = $c0 + [int][Math]::Round($f * $span)
                                  if ($ci -lt 0) { $ci = 0 } elseif ($ci -ge $nc) { $ci = $nc - 1 }
                                  $cc = $scrCols[$ci]
                                  $p = $i * 3
                                  for ($k = 0; $k -lt 3; $k++) {
                                      $cv = [double]$cc[$k]
                                      $cv = $cv + (1.0 - $cv) * $sFlashWht
                                      $gflat[$p+$k] = [int][Math]::Round(255 * $amp * $cv)
                                  }
                              }
                          } else {
                              # No column data (an older capture). Fall back to the
                              # whole-screen colour rather than showing nothing.
                              $zv = New-Object int[] 3
                              $zc = @($bR, $bG, $bB)
                              for ($k = 0; $k -lt 3; $k++) {
                                  $zv[$k] = [int][Math]::Round(255 * $amp * [double]$zc[$k])
                              }
                              for ($i = 0; $i -lt $gN; $i++) {
                                  $p = $i * 3
                                  $gflat[$p] = $zv[0]; $gflat[$p+1] = $zv[1]; $gflat[$p+2] = $zv[2]
                              }
                          }
                          for ($i = 0; $i -lt $gflat.Length; $i++) {
                              if ($gflat[$i] -gt 255) { $gflat[$i] = 255 } elseif ($gflat[$i] -lt 0) { $gflat[$i] = 0 }
                          }
                          [void](Send-GoveeSegments -Ip $lamp.Ip -Rgb $gflat -Header $lamp.Header)
                          continue
                      }

                      if (-not $gCache.ContainsKey($gN)) {

                    if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) {
                        # The wave still comes from the SHARED renderer so its
                        # motion, timing and cross-fade can never drift from the
                        # other surfaces - only the base hue is swapped, and it is
                        # put back immediately. Get-BlendedFrame reads these from
                        # the loop scope, which is exactly why this works.
                        # !! The lamp palette override applies to THINKING ONLY.
                        # Music mode computes a hue PER PIXEL inside the renderer,
                        # so forcing the lamp's yellow here would flatten the whole
                        # spectrum to one colour - the opposite of the point.
                        if ($state -eq 'thinking') {
                            $sR,$sG,$sB = $bR,$bG,$bB
                            $bR,$bG,$bB = $GoveeThinkRgb[0],$GoveeThinkRgb[1],$GoveeThinkRgb[2]
                            $gfr = Get-BlendedFrame $gN
                            $bR,$bG,$bB = $sR,$sG,$sB
                        } else {
                            $gfr = Get-BlendedFrame $gN
                        }
                    } else {
                        # Flat states. Deliberately NOT Get-FlatColor: that function
                        # carries its own hardcoded per-state ratios for the shared
                        # surfaces, so the lamp palette has to be applied here. The
                        # STRUCTURE below is a mirror of it on purpose - state
                        # colour first, then the red syllable layer taken as a max
                        # so the red stays pure instead of tinting toward the state
                        # underneath. Keep the two in step if either changes.
                        $lr = 0.0; $lg = 0.0; $lb = 0.0
                        if ($alert) {
                            $lr = $amp
                        } elseif ($state -eq 'music' -or $state -eq 'screen') {
                            # Music colour comes from the spectrum and screen
                            # colour from the monitor, so both use the base colour
                            # straight rather than the lamp palette - the lamp
                            # palette exists to correct FIXED state hues through
                            # the diffuser, and there is no fixed hue in either.
                            #
                            # !! THESE ARE THE FOUR LAMPS BRIAN ACTUALLY LOOKS AT.
                            # Without a 'screen' case here the state falls through
                            # to the final else and renders $GoveeIdleRgb - plain
                            # idle blue - which is precisely what he was seeing.
                            $lr = $amp*$bR; $lg = $amp*$bG; $lb = $amp*$bB
                        } elseif ($state -eq 'listening') {
                            $lr = $amp*$GoveeListenRgb[0]; $lg = $amp*$GoveeListenRgb[1]; $lb = $amp*$GoveeListenRgb[2]
                        } elseif ($state -eq 'speaking' -or $releasing) {
                            # Blue rises underneath on the release tail, same as
                            # everywhere else - $blueAmp already carries the fade.
                            $lr = $blueAmp*$GoveeIdleRgb[0]; $lg = $blueAmp*$GoveeIdleRgb[1]; $lb = $blueAmp*$GoveeIdleRgb[2]
                        } else {
                            $lr = $gBreath*$GoveeIdleRgb[0]; $lg = $gBreath*$GoveeIdleRgb[1]; $lb = $gBreath*$GoveeIdleRgb[2]
                        }
                        if ($ttsLive) {
                            $lr = [Math]::Max($lr, $voiceEnv * $GoveeSpeakRgb[0])
                            $lg = [Math]::Max($lg, $voiceEnv * $GoveeSpeakRgb[1])
                            $lb = [Math]::Max($lb, $voiceEnv * $GoveeSpeakRgb[2])
                        }
                        $vr=[int][Math]::Round(255*$lr); if($vr -gt 255){$vr=255}; if($vr -lt 0){$vr=0}
                        $vg=[int][Math]::Round(255*$lg); if($vg -gt 255){$vg=255}; if($vg -lt 0){$vg=0}
                        $vb=[int][Math]::Round(255*$lb); if($vb -gt 255){$vb=255}; if($vb -lt 0){$vb=0}
                        $gfr = New-Object byte[] ($gN * 4)
                        for ($i = 0; $i -lt $gN; $i++) { $o = $i*4; $gfr[$o]=[byte]$vr; $gfr[$o+1]=[byte]$vg; $gfr[$o+2]=[byte]$vb }
                    }
                    # Strip frames are 4 bytes per pixel; the Govee wire format is 3.
                        $gflat = New-Object int[] ($gN * 3)
                        for ($i = 0; $i -lt $gN; $i++) {
                            $o = $i * 4; $p = $i * 3
                            $gflat[$p] = $gfr[$o]; $gflat[$p+1] = $gfr[$o+1]; $gflat[$p+2] = $gfr[$o+2]
                        }
                        $gCache[$gN] = $gflat
                      }
                      [void](Send-GoveeSegments -Ip $lamp.Ip -Rgb $gCache[$gN] -Header $lamp.Header)
                    }
                }
            } catch {
                $script:roomFails++
                if ($script:roomFails -le 3 -or $script:roomFails % 300 -eq 0) {
                    Log "room lights: send failed #$($script:roomFails): $($_.Exception.Message)"
                }
                $chromaLink = $null
                $script:nextLinkTryAt = (Get-Date).AddSeconds(5)
            }
        }
    }

    # --- mouse, over the Chroma SDK.
    #
    # Deliberately AFTER the OpenRGB sends and wrapped whole, so nothing in here
    # can delay or break the hardware that actually matters. Same failure
    # philosophy as the OpenRGB recovery above - a flag that keeps retrying,
    # never a silent give-up - but on its OWN counters, so the two can't
    # cross-trigger each other.
    if (-not $NoMouse) {
        if (-not $chroma) {
            # Reconnect attempt. Cheap enough at 3 s intervals, and this is the
            # path that recovers the mouse after Synapse or the SDK services are
            # restarted without needing the whole loop bounced.
            if ((Get-Date) -ge $nextChromaTryAt) {
                try {
                    $chroma = Connect-Chroma
                    $lastChromaBeat = Get-Date
                    Log ("mouse: Chroma session re-opened ({0}) after $chromaTries failed attempt(s)" -f $chroma.SessionId)
                    $chromaTries = 0
                } catch {
                    $chromaTries++
                    if ($chromaTries -le 3 -or $chromaTries % 60 -eq 0) {
                        Log "mouse: Chroma reconnect attempt ${chromaTries} failed: $($_.Exception.Message)"
                    }
                    $nextChromaTryAt = (Get-Date).AddSeconds(3)
                }
            }
        } else {
            try {
                # Heartbeat first: losing the session costs more than a dropped
                # frame, and the server drops a quiet one after ~15 s.
                if (((Get-Date) - $lastChromaBeat).TotalSeconds -ge $ChromaBeatSec) {
                    Send-ChromaHeartbeat $chroma
                    $lastChromaBeat = Get-Date
                }
                if ($chromaFrameMs -gt 0 -and ((Get-Date) - $lastMouseAt).TotalMilliseconds -ge $chromaFrameMs) {
                    # Same bloom, same envelopes, same cross-fade as everything
                    # else - just rendered onto a 9-row strip and mapped down the
                    # mouse's grid, so it travels front-to-back along the underglow.
                    # The mouse takes the same flat colour as the keyboard and
                    # RAM now (Brian, 2026-08-01). The bloom-derived styles
                    # below are kept only for the 'bloom' option.
                    if (($state -eq 'thinking' -or $state -eq 'music') -and -not $alert) {
                        $mouseStrip = Get-BlendedFrame $script:CHROMA_MOUSE_ROWS
                    } else {
                        $mouseStrip = Get-FlatFrame $script:CHROMA_MOUSE_ROWS $flatRgb
                    }
                    if ($false) {
                        # Take the BRIGHTEST row and flood the whole mouse with
                        # it. Deliberately reuses the full strip render rather
                        # than recomputing a colour, so every envelope, the
                        # release tail and the additive blue cross-fade all still
                        # apply - the mouse just shows the peak of them instead
                        # of a narrow slice.
                        $bi = 0; $best = -1
                        for ($r = 0; $r -lt $script:CHROMA_MOUSE_ROWS; $r++) {
                            $o = $r * 4
                            $sum = [int]$mouseStrip[$o] + [int]$mouseStrip[$o+1] + [int]$mouseStrip[$o+2]
                            if ($sum -gt $best) { $best = $sum; $bi = $r }
                        }
                        $flat = New-Object byte[] ($script:CHROMA_MOUSE_ROWS * 4)
                        for ($r = 0; $r -lt $script:CHROMA_MOUSE_ROWS; $r++) {
                            $o = $r * 4; $b = $bi * 4
                            $flat[$o] = $mouseStrip[$b]; $flat[$o+1] = $mouseStrip[$b+1]; $flat[$o+2] = $mouseStrip[$b+2]
                        }
                        $mouseStrip = $flat
                    }
                    Send-ChromaMouseStrip $chroma $mouseStrip
                    $lastMouseAt = Get-Date
                }
            } catch {
                $chromaFails++
                Log "mouse: Chroma send failed ($($_.Exception.Message)) - dropping session and retrying"
                try { Disconnect-Chroma $chroma } catch { }
                $chroma          = $null
                $nextChromaTryAt = (Get-Date).AddSeconds(3)
            }
        }
    }

    # Heartbeat every ~10s so a future session can prove it is really running
    # and really seeing voice, instead of inferring it from a silent log.
    #
    # TIMED, not frame-counted. The old "$frames % ($Fps * 10) -eq 0" test broke
    # in exactly the situation the heartbeat exists for: when the device set went
    # empty, $frames stopped advancing, so the beat either went permanently
    # silent or - if it stalled on an exact multiple of 300 - fired every single
    # frame and flooded the log at 30 lines a second. It now also reports whether
    # it currently HAS hardware, so "running" and "actually painting something"
    # can be told apart from the log alone.
    if (((Get-Date) - $lastBeat).TotalSeconds -ge 10) {
        $health = if ($needsDiscovery) { "DEGRADED (no devices, retry #$discoveryTries)" } else { 'ok' }
        # Reported explicitly rather than inferred from silence - the whole
        # reason 'devices=DEGRADED' exists is that a clean log once hid a loop
        # painting nothing. The mouse gets the same treatment.
        $mouseHealth = if ($NoMouse) { 'off' }
                       elseif ($chroma) { "ok (fails=$chromaFails)" }
                       else { "DOWN (retry #$chromaTries)" }
        $extrasHealth = if ($NoExtras) { 'off' } else {
            $bits = @()
            if ($fans) { $bits += "fans$($fans.Leds)" } else { $bits += 'fans-' }
            if ($aura) { $bits += "aura$($aura.Leds)" } else { $bits += 'aura-' }
            if ($gpu)  { $bits += 'gpu' }              else { $bits += 'gpu-' }
            ($bits -join '/') + " fails=$extrasFails"
        }
        # Room lights get their OWN field for the same reason the mouse does: so
    # "the loop is running" and "the lamp is actually being painted" can be told
    # apart from the log alone. Without this a lamp that silently stopped
    # answering left a completely healthy-looking heartbeat.
    # Reports the REAL per-lamp segment counts, e.g. "ok x2 (10,8)". It used to
    # print a single shared number, which was actively misleading the moment the
    # second lamp arrived with a different count - and this field exists
    # specifically to diagnose lamp problems, so it must not lie.
    $goveeHealth = if ($script:GoveeLamps.Count -eq 0) { 'off' }
                   elseif ($script:roomFails -eq 0) { "ok x$($script:GoveeLamps.Count) ($(($script:GoveeLamps | ForEach-Object { $_.Segments }) -join ','))" }
                   else { "DEGRADED (fails=$($script:roomFails))" }
    # Music gets its own field for the same reason the lamps and the mouse do:
    # so "the loop is running" and "music is actually driving the lights" can be
    # told apart from the log alone.
    $musicHealth = if ($NoMusic) { 'off' }
                   elseif ($musicOff) { 'OFF (flag)' }
                   elseif ($musicOn) { "ON sty=$($script:musicStyle) lvl={0:N2} b/m/t={1:N2}/{2:N2}/{3:N2}" -f $mLevel, $mBass, $mMid, $mTreb }
                   elseif ($script:musicErrs -gt 0) { "err=$($script:musicErrs)" }
                   else { 'idle' }
    # Screen health reported the same way, and for the same reason: without it
    # the only way to know whether the screen is driving the lights is to ask
    # Brian what his room looks like. 'idle' here means the capture is not
    # running or has nothing changing on the monitor - both are normal.
    $screenHealth = if ($NoScreen) { 'off' }
                    elseif ($screenOff) { 'OFF (flag)' }
                    elseif ($screenOn) { "ON lvl={0:N2} rgb={1:N2}/{2:N2}/{3:N2}" -f $sLevel, $sR, $sG, $sB }
                    else { 'idle' }
    Log ("alive: frames=$frames state=$state level={0:N3} peak={1:N3} pollErrs=$pollErrs devices=$health mouse=$mouseHealth extras=$extrasHealth govee=$goveeHealth music=$musicHealth screen=$screenHealth" -f $level, $peakSeen)
        $peakSeen = 0.0
        $lastBeat = Get-Date
    }

    $el = [int]$sw.ElapsedMilliseconds
    if ($el -lt $frameMs) { Start-Sleep -Milliseconds ($frameMs - $el) }
}

Log "stop file seen - restoring steady white on every device, exiting"
try {
    foreach ($d in @($keyboard) + $ramParts + @($fans) + @($aura) + @($gpu)) {
        if (-not $d) { continue }
        $b = New-Object byte[] ($d.Leds * 4)
        for ($i = 0; $i -lt $d.Leds; $i++) { $o = $i * 4; $b[$o]=110; $b[$o+1]=110; $b[$o+2]=110 }
        try { Send-Frame $conn $d.Idx $b $d.Leds } catch { }
    }
    Disconnect-Orgb $conn
} catch { }

# Release the mouse explicitly. Closing the session hands the Basilisk straight
# back to Synapse's own effect - which is what Brian sees when the voice line
# isn't running, and is intended. Leaving it open would keep the mouse frozen on
# our last frame until the server's timeout eventually reaped it.
if ($chroma) {
    try { Disconnect-Chroma $chroma; Log 'mouse: Chroma session closed, mouse handed back to Synapse' }
    catch { Log "mouse: Chroma session close failed: $($_.Exception.Message)" }
}

# Release the Govee lamps the same way, and for the same reason. Leaving them in
# segment mode would strand them on our last frame and keep them out of Brian's
# own Govee app until the loop ran again - his lamps, not our scratch devices.
# A last flat colour is sent first so they land on the idle blue rather than on
# whatever half-rendered frame happened to be last.
if ($GoveeIps.Count -gt 0) {
    foreach ($ip in $GoveeIps) {
        try {
            [void](Set-GoveeColor -Ip $ip -R 25 -G 76 -B 229)
            Start-Sleep -Milliseconds 60
            [void](Disable-GoveeSegments -Ip $ip)
        } catch { }
    }
    try { Close-GoveeStreamClient } catch { }
    Log "govee: segment mode released on $($GoveeIps.Count) lamp(s), handed back to the Govee app"
}

# Drop the PID lock so the next launch does not have to fall back on the
# stale-detection path. If this line never runs (hard kill), the PID + start-time
# check above still clears it correctly - this is the tidy exit, not the safety net.
Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
Remove-Item $StopFile -Force -ErrorAction SilentlyContinue

