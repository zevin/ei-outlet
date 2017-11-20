#require "ConnectionManager.lib.nut:2.0.0"

// Instantiate ConnectionManager so BlinkUp is always enabled,
// and we automatically agressively try to reconnect on disconnect
cm <- ConnectionManager({
    "blinkupBehavior" : ConnectionManager.BLINK_ALWAYS,
    "stayConnected" : true
});

// Powertech test code
server.log("imp :" + imp.getsoftwareversion());
server.log("boot:" + imp.getbootromversion());
imp.enableblinkup(true);

// Pin definitions
reset <- hardware.pinB;
cs <- hardware.pin8;
spi <- hardware.spi257;
relay0 <- hardware.pinA;
relay1 <- hardware.pin9;

// Setup pins
reset.configure(DIGITAL_OUT, 0);
cs.configure(DIGITAL_OUT, 0);
spi.configure(CLOCK_IDLE_LOW, 100);
relay0.configure(DIGITAL_OUT, 0);
relay1.configure(DIGITAL_OUT, 0);

// We don't know if we were on or off
local switchstate = -1;
local watts = 0.0;

// 200ms pulse
local function pulse(r) {
    r.write(1);
    imp.wakeup(0.2, function() { r.write(0); });
}

// Input: relay control
agent.on("power", function(v){
    server.log(v);
    if (v != switchstate) pulse(v==0?relay0:relay1);
    switchstate = v;
});

function sendstate() {
    local s=format("%6.1f W", watts);
}

function init() {
    // Reset PL into MCU mode
    reset.write(0);
    cs.write(0);
    imp.sleep(0.1);
    reset.write(1);
    imp.sleep(0.1);
    cs.write(1);
    imp.sleep(0.1);

    // Check if chip is ready
    cs.write(0);
    spi.write("\x78\x60");
    local r = spi.readstring(1)[0];
    cs.write(1);
    //server.log(format("read %02x", r));
    
    return r == 0x04;
}

function waitstatus() {
    // Check status until we're good
    cs.write(0);
    spi.writeread("\xc0\x00\xff");
    local s;
    local c=0;
    do {
        s=spi.writeread("\xff");
        c++;
    } while((s[0]&0x80)==0);
    cs.write(1);
//    server.log(format("s=%02x c=%d", s[0], c));
}

function read(r, l) {
    // Read page
    r = r | 0x4000;
    local addr = format("%c%c", (r>>8)&0xff, r&0xff);
    
    cs.write(0);
    spi.write(addr);

    // Discovered: spi blob reads send 0xa5 as the "arbitrary" data. This upsets the chip, which prefers zero.
    // Have checked in a fix to the SPIIO stuff
    local b = blob(l);
    for(local a=0;a<l;a++) b[a]=spi.writeread("\x00")[0];
    
    cs.write(1);
    return b;
}

function getword(b, p) {
    return((b[p+1]<<8)|b[p]);
}

function loop() {
    imp.wakeup(1,loop);
    
    // Wait for DSP ready, then read our data
    waitstatus();
    local b = read(0x3000, 144);
    local b2 = read(0x3809, 2);
   
    // Basic calculations
    local va_rms = getword(b,2)/64.0;
    local ia_rms = getword(b,8)/256.0;
    local power = getword(b,123);
    local va = va_rms * ia_rms;
    local power_factor = power/va;
    local phase_angle = (math.acos(power_factor)/(2*PI))*360;
    
    // Frequency = [Sample_cnt0/(ZCC_STOP-ZCC_START)]*[(ZCC_CNT-1)/2]
	local Sample_cnt0 = getword(b2,0);
    local ZCC_cnt = getword(b,90);
    local ZCC_stop = getword(b,96);
    local ZCC_start = getword(b,102);
	local frequency = ((1.0 * Sample_cnt0) / (ZCC_stop - ZCC_start)) * ((ZCC_cnt - 1.0) / 2);
    
    //server.log(format("va_rms=%.2fV ia_rms=%.2fA power=%dW va=%.2f powerfactor=%.2f phaseangle=%.2f freq=%.2f",va_rms,ia_rms,power,va,power_factor,phase_angle,frequency));
    
    // Externally visible power
    watts = power;
    
    // If we just rebooted and don't know if we're on or off, work it out from power draw
    //if (switchstate == -1) {
    //    switchstate = (watts > 1)?1:0;
    //}

    sendstate();
}

// Initialize chip
while(!init());

// Start reading power
//loop();