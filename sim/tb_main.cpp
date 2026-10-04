// SPDX-License-Identifier: GPL-2.0-or-later
// Taito B System core for MiSTer - whole-core simulation driver.
//
//   tb --rom sim/work/ryujina.rom --dip sim/work/ryujina.dip --script sim/scenarios/x.txt
//      [--out sim/out/x] [--quiet]
//
// The scenario is a list of "<frame> <command> [args]" lines run when the analog VSync
// count reaches <frame> (frame 0 = time zero, before anything is loaded). Commands:
//   status <msb> <lsb> <value>   set status[msb:lsb] (what the OSD writes)
//   joy <n> <hex>                MiSTer joystick word for player n
//   dv <0|1>                     Direct Video
//   sd <0|1>                     forced scandoubler (31 kHz)
//   load_rom                     DDR-mode ROM download (index 0), as an MRA with address=
//   load_dip                     DIP switch download (index 254)
//   reset_pulse                  OSD reset: status[0] high for one frame
//   segment <name>               start a new timing-report segment
//   shot <name>                  save the next native analog frame as <out>_<name>.ppm
//   fbshot <name>                save the screen_rotate framebuffer as <out>_<name>_fb.ppm
//   probe_joy <name>             log the joystick word reaching the game core
//   end                          stop
//
// The monitor watches what leaves the core and the framework's analog stage, edge by
// edge: emu's CE_PIXEL/VGA_HS/VGA_VS/VGA_DE and, after sys_top's sync_fix, scanlines and
// csync, ana_hs/ana_vs/ana_de/ana_cs. Every period and width is histogrammed per segment
// in CLK_VIDEO cycles; anything off the segment's dominant value is reported with its
// frame number, so a single short or missing pulse at a transition cannot hide.

#include "Vtb_top.h"
#include "Vtb_top__Dpi.h"
#include "svdpi.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <unordered_map>
#include <fstream>
#include <sstream>

static Vtb_top *top;
static uint32_t status_w[4];
static uint32_t joy[2];
static int video_flags;
static std::vector<uint8_t> rom, dip;
static std::unordered_map<uint32_t, uint64_t> ddr;
static std::vector<int> dl_queue;      // downloads waiting for the previous one to finish
static bool dl_busy = false;
static int video_rotated_now = 0;
static uint64_t cyc = 0;           // clk_sys cycles
static long frame = 0;             // analog VSync rising edges seen
static std::string outbase = "sim/out/run";
static bool quiet = false;

double sc_time_stamp() { return (double)cyc; }

// ---------------------------------------------------------------- DPI
extern "C" int sim_status_word(int i) { return (int)status_w[i & 3]; }
extern "C" int sim_joy(int n) { return (int)joy[n & 1]; }
extern "C" int sim_video_flags() { return video_flags; }
extern "C" int sim_download_start() {
    if (!dl_queue.empty() && !dl_busy) { int i = dl_queue.front(); dl_queue.erase(dl_queue.begin()); dl_busy = true; return i; }
    return -1;
}
extern "C" int sim_download_ddr(int index) { return index == 0; }
extern "C" int sim_download_size(int index) { return index == 0 ? (int)rom.size() : (int)dip.size(); }
extern "C" int sim_download_byte(int index, int addr) {
    const std::vector<uint8_t> &v = index == 0 ? rom : dip;
    return addr < (int)v.size() ? v[addr] : 0xff;
}
extern "C" void sim_download_done(int index) {
    dl_busy = false;
    printf("[f%ld c%llu] download index %d done\n", frame, (unsigned long long)cyc, index);
}
extern "C" void sim_core_status(int w0, int w1, int w2, int w3) {
    uint32_t n[4] = {(uint32_t)w0, (uint32_t)w1, (uint32_t)w2, (uint32_t)w3};
    n[0] &= ~1u;   // Main_MiSTer: user_io_status_set("[0]", 0)
    printf("[f%ld] core set status: %08x %08x %08x %08x\n", frame, n[3], n[2], n[1], n[0]);
    memcpy(status_w, n, sizeof n);
}
extern "C" void sim_video_rotated(int r) {
    video_rotated_now = r;
    printf("[f%ld] video_rotated -> %d\n", frame, r);
}
extern "C" long long sim_ddr_read(int addr) {
    auto it = ddr.find((uint32_t)addr);
    return it == ddr.end() ? 0 : (long long)it->second;
}
extern "C" void sim_ddr_write(int addr, long long data, int be) {
    uint64_t &w = ddr[(uint32_t)addr];
    for (int b = 0; b < 8; b++)
        if (be & (1 << b)) w = (w & ~(0xffull << (8 * b))) | ((uint64_t)data & (0xffull << (8 * b)));
}

static void set_bits(int msb, int lsb, uint64_t v) {
    for (int b = lsb; b <= msb; b++) {
        uint32_t &w = status_w[b >> 5];
        uint32_t m = 1u << (b & 31);
        w = ((v >> (b - lsb)) & 1) ? (w | m) : (w & ~m);
    }
}

// ---------------------------------------------------------------- timing monitor
struct Hist {
    std::map<long, long> h;
    void add(long v) { h[v]++; }
    long mode() const { long best = 0, n = -1; for (auto &p : h) if (p.second > n) { n = p.second; best = p.first; } return best; }
    long total() const { long t = 0; for (auto &p : h) t += p.second; return t; }
    std::string str(int maxn = 6) const {
        std::ostringstream o; int k = 0;
        for (auto &p : h) { if (k++ >= maxn) { o << " ..."; break; } o << " " << p.first << "x" << p.second; }
        return o.str();
    }
};

struct EdgeMon {
    const char *name;
    bool prev = false;
    uint64_t rise = 0, fall = 0;
    bool have_rise = false, have_fall = false;
    Hist period, width_hi, width_lo;
    std::vector<std::pair<long, long>> odd;   // (frame, period) of the first few unusual periods
    void reset() { period = Hist(); width_hi = Hist(); width_lo = Hist(); have_rise = have_fall = false; }
    void step(bool v) {
        if (v && !prev) {
            if (have_rise) period.add((long)(cyc - rise));
            if (have_fall) width_lo.add((long)(cyc - fall));
            rise = cyc; have_rise = true;
        }
        if (!v && prev) {
            if (have_rise) width_hi.add((long)(cyc - rise));
            fall = cyc; have_fall = true;
        }
        prev = v;
    }
};

struct Seg {
    std::string name;
    long start_frame;
    EdgeMon ce{"CE_PIXEL"}, hs{"VGA_HS"}, vs{"VGA_VS"}, ahs{"ana_hs"}, avs{"ana_vs"}, acs{"ana_cs"}, ade{"ana_de"};
    Hist px_per_line, lines_per_frame, hs_to_vs, de_lines_mode, fp_px;
    Hist hs_to_de, de_to_hs, vfp_lines, vbp_lines;   // porches at the analog output, in clk / lines
    uint64_t de_fall = 0; bool de_fell = false;
    long hs_since_de = 0, hs_since_vs = 0; bool after_de = false, after_vs = false;
    long px = 0, lines = 0;
    bool in_line = false;
    uint64_t last_ahs_rise = 0;
    bool ahs_prev2 = false, ade_prev2 = false, avs_prev2 = false;
};

static Seg seg;
static std::vector<std::string> report;

static void seg_report() {
    if (seg.name.empty()) return;
    std::ostringstream o;
    auto line = [&](const EdgeMon &m) {
        o << "    " << m.name << ": period" << m.period.str() << " | high" << m.width_hi.str() << " | low" << m.width_lo.str() << "\n";
    };
    o << "== segment '" << seg.name << "' frames " << seg.start_frame << ".." << frame << "\n";
    line(seg.ce); line(seg.hs); line(seg.vs); line(seg.ahs); line(seg.avs); line(seg.acs); line(seg.ade);
    o << "    porches: HS rise->DE rise" << seg.hs_to_de.str() << " | DE fall->HS rise" << seg.de_to_hs.str()
      << " | VS: lines last-DE->VS" << seg.vfp_lines.str() << " | lines VS->first-DE" << seg.vbp_lines.str() << "\n";
    o << "    active px/line" << seg.px_per_line.str() << " | active lines/frame" << seg.lines_per_frame.str()
      << " | ana VS rise - ana HS rise (clk)" << seg.hs_to_vs.str() << "\n";
    report.push_back(o.str());
    if (!quiet) fputs(o.str().c_str(), stdout);
}

static void seg_start(const std::string &name) {
    seg_report();
    seg = Seg();
    seg.name = name;
    seg.ce.prev = top->ce_pixel; seg.hs.prev = top->vga_hs; seg.vs.prev = top->vga_vs;
    seg.ahs.prev = top->ana_hs; seg.avs.prev = top->ana_vs; seg.acs.prev = top->ana_cs; seg.ade.prev = top->ana_de;
    seg.ahs_prev2 = top->ana_hs; seg.ade_prev2 = top->ana_de; seg.avs_prev2 = top->ana_vs;
    seg.start_frame = frame;
}

// ---------------------------------------------------------------- frame capture
static std::string shot_pending, fbshot_pending;
static bool pair_pending = false, pair_active = false;
static int pair_buf = 0;
static bool shooting = false;
static std::vector<uint32_t> img;
static int img_w = 0, img_h = 0, cap_x = 0, cap_y = 0;
static bool prev_de_cap = false;

static void write_ppm(const std::string &fn, int w, int h, const std::vector<uint32_t> &px) {
    FILE *f = fopen(fn.c_str(), "wb");
    if (!f) { printf("cannot write %s\n", fn.c_str()); return; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; i++) { uint8_t c[3] = {(uint8_t)(px[i] >> 16), (uint8_t)(px[i] >> 8), (uint8_t)px[i]}; fwrite(c, 1, 3, f); }
    fclose(f);
    printf("[f%ld] wrote %s (%dx%d)\n", frame, fn.c_str(), w, h);
}

// buf < 0: the buffer the scaler is reading now; else screen_rotate buffer `buf`
static void fb_dump(const std::string &name, int buf = -1) {
    if (!top->fb_en) { printf("[f%ld] fbshot %s: FB_EN low, nothing to dump\n", frame, name.c_str()); return; }
    int w = top->fb_width, h = top->fb_height, stride = top->fb_stride;
    uint32_t base = buf < 0 ? top->fb_base : 0x24000000u + ((uint32_t)buf << 23);
    std::vector<uint32_t> px(w * h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint32_t b = base + y * stride + x * 4;
            uint64_t word = ddr.count(b >> 3) ? ddr[b >> 3] : 0;
            uint32_t v = (uint32_t)(word >> ((b & 4) ? 32 : 0));
            uint8_t r = v & 0xff, g = (v >> 8) & 0xff, bl = (v >> 16) & 0xff;
            px[y * w + x] = (r << 16) | (g << 8) | bl;
        }
    printf("[f%ld] FB %dx%d stride %d base %08x ARX/ARY %d:%d\n", frame, w, h, stride, base, top->arx, top->ary);
    write_ppm(outbase + "_" + name + "_fb.ppm", w, h, px);
}

// ---------------------------------------------------------------- scenario
struct Ev { long frame; std::string cmd; std::vector<std::string> a; };
static std::vector<Ev> evs;
static size_t ev_i = 0;
static long reset_until = -1;
static long trace_frames = 0;
static std::map<uint32_t, long> trace_hist;
static bool prev_as = true, prev_as2 = true;
static long tracelog_left = 0;
static long nz_pix = 0, nz_r = 0, nz_vga = 0;
static uint32_t last_a = 0xffffffff;
static bool done = false;

static void run_event(const Ev &e) {
    if (!quiet) printf("[f%ld] %s", frame, e.cmd.c_str());
    for (auto &s : e.a) if (!quiet) printf(" %s", s.c_str());
    if (!quiet) printf("\n");
    if (e.cmd == "status") set_bits(std::stoi(e.a[0]), std::stoi(e.a[1]), std::stoull(e.a[2], nullptr, 0));
    else if (e.cmd == "joy") joy[std::stoi(e.a[0]) & 1] = (uint32_t)std::stoul(e.a[1], nullptr, 16);
    else if (e.cmd == "dv") video_flags = (video_flags & ~1) | (std::stoi(e.a[0]) & 1);
    else if (e.cmd == "sd") video_flags = (video_flags & ~2) | ((std::stoi(e.a[0]) & 1) << 1);
    else if (e.cmd == "load_rom") {
        // Main_MiSTer writes the file into DDR3 at the MRA address before signalling
        for (size_t i = 0; i < rom.size(); i += 8) {
            uint64_t w = 0;
            for (int b = 0; b < 8 && i + b < rom.size(); b++) w |= (uint64_t)rom[i + b] << (8 * b);
            ddr[(0x30000000u + (uint32_t)i) >> 3] = w;
        }
        dl_queue.push_back(0);
    }
    else if (e.cmd == "load_dip") dl_queue.push_back(254);
    else if (e.cmd == "reset_pulse") { set_bits(0, 0, 1); reset_until = frame + 1; }
    else if (e.cmd == "segment") seg_start(e.a[0]);
    else if (e.cmd == "shot") shot_pending = e.a[0];
    else if (e.cmd == "shotpair") { shot_pending = e.a[0]; pair_pending = true; }
    else if (e.cmd == "fbshot") fb_dump(e.a[0]);
    else if (e.cmd == "probe_joy") printf("[f%ld] probe %s: orient=%u MiSTer joy0=%03x -> game joystick_p1=%03x %s\n", frame,
                                          e.a[0].c_str(), (status_w[1] >> 8) & 3, joy[0] & 0x3ff, top->game_joy1,
                                          (top->game_joy1 == (joy[0] & 0x3ff)) ? "(unchanged)" : "(REMAPPED)");
    else if (e.cmd == "trace") trace_frames = std::stol(e.a[0]);
    else if (e.cmd == "tracelog") { tracelog_left = std::stol(e.a[0]); }
    else if (e.cmd == "end") done = true;
    else { printf("unknown command %s\n", e.cmd.c_str()); exit(2); }
}

static std::vector<uint8_t> slurp(const char *fn) {
    std::ifstream f(fn, std::ios::binary);
    if (!f) { printf("cannot read %s\n", fn); exit(2); }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    setvbuf(stdout, nullptr, _IOLBF, 0);
    const char *script = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--rom")) rom = slurp(argv[++i]);
        else if (!strcmp(argv[i], "--dip")) dip = slurp(argv[++i]);
        else if (!strcmp(argv[i], "--script")) script = argv[++i];
        else if (!strcmp(argv[i], "--out")) outbase = argv[++i];
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
    }
    if (!script) { printf("--script required\n"); return 2; }
    {
        std::ifstream f(script);
        std::string ln;
        while (std::getline(f, ln)) {
            if (ln.empty() || ln[0] == '#') continue;
            std::istringstream is(ln);
            Ev e; is >> e.frame >> e.cmd;
            std::string s; while (is >> s) e.a.push_back(s);
            evs.push_back(e);
        }
    }

    top = new Vtb_top;
    top->hdmi_w = 1920; top->hdmi_h = 1080;
    top->clk_sdr = 0; top->fb_vbl = 0;
    top->eval();

    const uint64_t HDMI_FRAME = 905467, HDMI_VBL = 27000;   // 60 Hz at 54.328 MHz
    bool prev_clk = false, prev_avs = false;
    uint64_t sdr_edges = 0;

    while (!done) {
        top->clk_sdr = !top->clk_sdr;
        top->eval();
        sdr_edges++;
        bool clk = top->clk_video;
        if (clk && !prev_clk) {
            cyc++;
            top->fb_vbl = (cyc % HDMI_FRAME) < HDMI_VBL;

            // ---- monitor (sampled on the CLK_VIDEO edge, values settled from the last one)
            seg.ce.step(top->ce_pixel);
            seg.hs.step(top->vga_hs);
            seg.vs.step(top->vga_vs);
            seg.ahs.step(top->ana_hs);
            seg.avs.step(top->ana_vs);
            seg.acs.step(top->ana_cs);
            seg.ade.step(top->ana_de);
            {
                bool hs_r = top->ana_hs && !seg.ahs_prev2, de_r = top->ana_de && !seg.ade_prev2, de_f = !top->ana_de && seg.ade_prev2;
                bool vs_r = top->ana_vs && !seg.avs_prev2;
                if (hs_r) {
                    if (seg.de_fell) { seg.de_to_hs.add((long)(cyc - seg.de_fall)); seg.de_fell = false; }
                    if (seg.after_de) seg.hs_since_de++;
                    if (seg.after_vs) seg.hs_since_vs++;
                }
                if (de_r) {
                    if (seg.ahs.have_rise) seg.hs_to_de.add((long)(cyc - seg.ahs.rise));
                    if (seg.after_vs) { seg.vbp_lines.add(seg.hs_since_vs); seg.after_vs = false; }
                    seg.after_de = false;
                }
                if (de_f) { seg.de_fall = cyc; seg.de_fell = true; seg.after_de = true; seg.hs_since_de = 0; }
                if (vs_r) {
                    if (seg.after_de) seg.vfp_lines.add(seg.hs_since_de);
                    seg.after_de = false; seg.after_vs = true; seg.hs_since_vs = 0;
                }
                seg.ahs_prev2 = top->ana_hs; seg.ade_prev2 = top->ana_de; seg.avs_prev2 = top->ana_vs;
            }
            if (top->ana_ce) {
                if (top->ana_de) { seg.px++; seg.in_line = true; }
                else if (seg.in_line) { seg.px_per_line.add(seg.px); seg.px = 0; seg.in_line = false; seg.lines++; }
            }
            bool avs = top->ana_vs;
            if (avs && !prev_avs) {
                if (seg.lines) seg.lines_per_frame.add(seg.lines);
                seg.lines = 0;
                if (seg.ahs.have_rise) seg.hs_to_vs.add((long)(cyc - seg.ahs.rise));
                frame++;
                if (trace_frames > 0 && --trace_frames == 0) {
                    printf("[f%ld] bus trace (%zu addresses):\n", frame, trace_hist.size());
                    for (auto &p : trace_hist) printf("   %06x x%ld\n", p.first, p.second);
                    trace_hist.clear();
                }
                if (reset_until >= 0 && frame >= reset_until) { set_bits(0, 0, 0); reset_until = -1; }
                if (shooting) {
                    write_ppm(outbase + "_" + shot_pending + ".ppm", img_w, img_h, img);
                    // the screen_rotate buffer written during that same frame
                    if (pair_active) { fb_dump(shot_pending, pair_buf); pair_active = false; }
                    shooting = false; shot_pending.clear();
                }
                else if (!shot_pending.empty()) {
                    shooting = true; img.assign(320 * 240, 0); img_w = 320; img_h = 0; cap_y = -1;
                    if (pair_pending) { pair_pending = false; pair_active = true; pair_buf = top->rot_ifb; }
                }
                while (ev_i < evs.size() && evs[ev_i].frame <= frame) run_event(evs[ev_i++]);
                if (frame % 30 == 0) printf("[f%ld] %llu clk  reset=%d cpu A=%06x AS=%d vcu_video_en=%d flip=%d\n", frame,
                    (unsigned long long)cyc, top->game_reset, top->cpu_a, top->cpu_as_n, top->vcu_video_en, top->vcu_flip),
                    printf("      nonzero clocks in last 30 frames: vcu_pixel %ld core_r %ld vga_r&de %ld\n", nz_pix, nz_r, nz_vga),
                    nz_pix = nz_r = nz_vga = 0;
            }
            prev_avs = avs;

            // ---- CPU bus trace: addresses of bus cycles, per frame
            if (trace_frames > 0) {
                bool as = top->cpu_as_n;
                if (!as && prev_as) trace_hist[top->cpu_a]++;
                prev_as = as;
            }
            if (top->vcu_pixel) nz_pix++;
            if (top->core_r) nz_r++;
            if (top->vga_r && top->vga_de) nz_vga++;
            // ---- ordered bus log, end of each bus cycle, delay loop 16e-180 skipped
            if (tracelog_left > 0) {
                bool as = top->cpu_as_n;
                if (as && !prev_as2) {
                    uint32_t a = last_a;
                    if ((a < 0x16e || a > 0x180) && a >= 0x80000 && (a < 0x100000 || a >= 0x110000)) {
                        printf("  f%ld %06x %s %04x\n", frame, a, top->cpu_rw ? "R" : "W", top->cpu_rw ? top->cpu_din : top->cpu_dout);
                        tracelog_left--;
                    }
                }
                if (!as) last_a = top->cpu_a;
                prev_as2 = as;
            }
            // ---- native capture
            if (shooting && top->ana_ce) {
                bool de = top->ana_de;
                if (de && !prev_de_cap) { cap_y++; cap_x = 0; if (cap_y + 1 > img_h) img_h = cap_y + 1; }
                if (de && cap_y >= 0 && cap_y < 240 && cap_x < 320) img[cap_y * 320 + cap_x] = top->ana_rgb;
                if (de) cap_x++;
                prev_de_cap = de;
            }
            if (cyc == 1) while (ev_i < evs.size() && evs[ev_i].frame <= 0) run_event(evs[ev_i++]);
        }
        prev_clk = clk;
    }
    seg_report();
    std::ofstream rf(outbase + "_timing.txt");
    for (auto &s : report) rf << s;
    delete top;
    return 0;
}
