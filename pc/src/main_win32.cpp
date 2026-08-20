// TrackpadTyping for Windows — Win32 shell around the portable engine.
//
// Same design as the macOS original: an always-on-top keyboard panel, the
// pointer is the input, press-and-hold-click traces a word, release commits.
// Clicks and scrolling are captured by low-level hooks while the keyboard is
// up; text lands in whatever window has focus via SendInput.
//
// Build (MSVC):  cl /std:c++17 /O2 /EHsc main_win32.cpp /Fe:TrackpadTyping.exe user32.lib gdi32.lib shell32.lib
// Build (MinGW): g++ -std=c++17 -O2 -mwindows -o TrackpadTyping.exe main_win32.cpp -lgdi32 -lshell32
// Run with lexicon-en.txt next to the .exe.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <commctrl.h>
#include <string>
#include <vector>
#include "engine.hpp"

using namespace tpt;

// ------------------------------------------------------------------- state --
static Config g_cfg;
static KeyboardLayout* g_layout;
static Lexicon* g_lexicon;
static Decoder* g_decoder;

static HWND g_hwnd;
static bool g_glideMode = false;
static bool g_tracing = false;
static std::vector<Pt> g_tracePath;
static std::vector<double> g_traceDwell;

static std::vector<Candidate> g_candidates;
static int g_selectedIndex = 0;
static double g_candOffset = 0;
static std::wstring g_status = L"Ctrl+Alt+Space toggles glide typing";

struct Commit { std::vector<std::string> cands; int index; int insertedLength; std::string tail; bool capitalized; };
static bool g_hasCommit = false;
static Commit g_commit;

static std::string g_typed;
static std::string g_letterRun;
static bool g_letterRunCapitalized = false;
static bool g_shiftPending = false;
static std::string g_pendingReinforce;
static int g_replaceLo = -1, g_replaceHi = -1;
static ULONGLONG g_lastSpaceTap = 0;
static std::vector<std::string> g_bank;

static bool g_deleteHeld = false;
static ULONGLONG g_deleteSince = 0;
static int g_deleteRepeats = 0;
static POINT g_savedCursor;
static bool g_draggingPanel = false;
static POINT g_dragOffset;
static ULONGLONG g_chipPressedAt = 0;
static std::string g_chipPressedWord;
static NOTIFYICONDATAW g_tray = {};

// Hover (click-free, joystick-friendly) mode: dwell arms a word on a letter,
// stops mid-word never commit, pushing up out of the grid types the word,
// and dwelling on any control activates it.
static bool g_hoverMode = false;
static bool g_hoverTracing = false;
static std::vector<Pt> g_hoverPath;
static std::vector<double> g_hoverDwell;
static POINT g_hoverLast = {-9999, -9999};
static double g_dwellTargetTime = 0;
static std::string g_dwellToken;
static bool g_dwellFired = false;
static bool g_dwellLive = false;
static ULONGLONG g_dwellEngineStart = 0;
static double g_armStillTotal = -1;
static double g_dwellProgress = 0;         // 0 hides the ring
static POINT g_dwellPoint = {0, 0};
static double HOVER_START_MS = 450, DWELL_ACTIVATE_MS = 650, HOVER_LETTER_MS = 1100;
static const double COMMIT_EXIT_BUFFER = 12, PAUSE_MAX_MS = 1200;

// ---------------------------------------------------------------- geometry --
// Panel layout in client coordinates (y down, unlike the engine's y-up).
static const int MARGIN = 10, GRABBER_H = 16, TEXTBAR_H = 32, STRIP_H = 46,
                 SPACEROW_H = 34, BANK_H = 34;
static int panelW() { return (int)g_layout->width + MARGIN * 2; }
static int panelH() {
    return (int)g_layout->height + MARGIN * 2 + GRABBER_H + TEXTBAR_H + STRIP_H + SPACEROW_H + BANK_H;
}
static RECT keyArea() {
    int top = GRABBER_H + TEXTBAR_H + STRIP_H;
    return {MARGIN, top, MARGIN + (int)g_layout->width, top + (int)g_layout->height};
}
// engine space (y up, origin bottom-left of key area) <-> client space
static Pt toEngine(POINT c) {
    RECT ka = keyArea();
    return {(double)(c.x - ka.left), (double)(ka.bottom - c.y)};
}
static POINT keyCenterClient(char ch) {
    RECT ka = keyArea();
    Pt p = g_layout->keys.at(ch);
    return {ka.left + (LONG)p.x, ka.bottom - (LONG)p.y};
}
static RECT spaceBar() {
    RECT ka = keyArea();
    int w = (int)(g_layout->keyPitch * 5);
    int x = (ka.left + ka.right) / 2 - w / 2;
    return {x, ka.bottom + 3, x + w, ka.bottom + SPACEROW_H - 3};
}
static const wchar_t* PUNCT[6] = {L"\x21E7", L"'", L",", L".", L"?", L"!"};
static const char* PUNCT_CH[6] = {"", "'", ",", ".", "?", "!"};
static RECT punctRect(int i) {
    RECT ka = keyArea(); RECT sp = spaceBar();
    int y0 = sp.top, y1 = sp.bottom;
    if (i <= 2) {
        int w = (sp.left - ka.left - 8) / 3;
        int x = ka.left + i * (w + 3);
        return {x, y0, x + w, y1};
    }
    int w = (ka.right - sp.right - 10) / 3;
    int x = sp.right + 4 + (i - 3) * (w + 3);
    return {x, y0, x + w, y1};
}
static RECT deleteKey() {
    RECT ka = keyArea();
    int pitch = (int)g_layout->keyPitch;
    return {ka.left + (int)(pitch * 8.55), (LONG)(ka.bottom - g_layout->rowPitch + 2),
            ka.right - 2, ka.bottom - 2};
}
static const int HOVER_TOGGLE_W = 58;
static RECT hoverToggleRect() {
    int top = panelH() - BANK_H + 4;
    return {MARGIN, top, MARGIN + HOVER_TOGGLE_W, top + BANK_H - 12};
}
static RECT bankSlot(int i, int n) {
    int top = panelH() - BANK_H + 2;
    int left = MARGIN + HOVER_TOGGLE_W + 6;
    int w = (panelW() - left - MARGIN) / (n > 0 ? n : 1);
    return {left + i * w + 3, top, left + (i + 1) * w - 3, top + BANK_H - 8};
}
static RECT stripRect() { return {MARGIN, GRABBER_H + TEXTBAR_H, panelW() - MARGIN, GRABBER_H + TEXTBAR_H + STRIP_H}; }
static RECT textBar() { return {MARGIN, GRABBER_H + 2, panelW() - MARGIN, GRABBER_H + TEXTBAR_H - 2}; }

static std::vector<RECT> g_chipRects;               // filled during paint
struct TypedWordRect { RECT r; int lo, hi; };
static std::vector<TypedWordRect> g_typedWordRects;

// --------------------------------------------------------------- injection --
static const ULONG_PTR INJECT_TAG = 0x54505459;     // "TPTY": ignore our own input

static void sendKey(WORD vk, bool down, bool unicodeChar = false, wchar_t ch = 0) {
    INPUT in = {};
    in.type = INPUT_KEYBOARD;
    in.ki.dwExtraInfo = INJECT_TAG;
    if (unicodeChar) {
        in.ki.wScan = ch;
        in.ki.dwFlags = KEYEVENTF_UNICODE | (down ? 0 : KEYEVENTF_KEYUP);
    } else {
        in.ki.wVk = vk;
        in.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
    }
    SendInput(1, &in, sizeof(INPUT));
}
static void injectRaw(const std::wstring& text) {
    for (wchar_t ch : text) { sendKey(0, true, true, ch); sendKey(0, false, true, ch); }
}
static void backspaceRaw(int n) { for (int i = 0; i < n; i++) { sendKey(VK_BACK, true); sendKey(VK_BACK, false); } }

static std::wstring widen(const std::string& s) { return std::wstring(s.begin(), s.end()); }

static void refresh() { InvalidateRect(g_hwnd, nullptr, FALSE); }
static void clearReplaceTarget() { g_replaceLo = g_replaceHi = -1; }

static void inject(const std::string& text) {
    injectRaw(widen(text));
    g_typed += text;
    g_lastSpaceTap = 0;
    clearReplaceTarget();
    refresh();
}
static void eraseN(int n) {
    if (n <= 0) return;
    backspaceRaw(n);
    g_typed.resize(g_typed.size() >= (size_t)n ? g_typed.size() - n : 0);
    g_lastSpaceTap = 0;
    clearReplaceTarget();
    refresh();
}
static void eraseWord() {                            // mirror of Ctrl+Backspace
    sendKey(VK_CONTROL, true); sendKey(VK_BACK, true);
    sendKey(VK_BACK, false); sendKey(VK_CONTROL, false);
    while (!g_typed.empty() && g_typed.back() == ' ') g_typed.pop_back();
    while (!g_typed.empty() && g_typed.back() != ' ') g_typed.pop_back();
    clearReplaceTarget();
    refresh();
}

// ------------------------------------------------------------ typing logic --
static std::string learnedPath();
static std::string appDataDir();
static std::string settingsPath() { return appDataDir() + "\\settings.txt"; }

static void saveSettings() {
    std::ofstream f(settingsPath(), std::ios::trunc);
    f << "hoverStartMS " << HOVER_START_MS << "\n"
      << "dwellActivateMS " << DWELL_ACTIVATE_MS << "\n"
      << "hoverLetterMS " << HOVER_LETTER_MS << "\n";
}
static void loadSettings() {
    std::ifstream f(settingsPath());
    std::string k; double v;
    while (f >> k >> v) {
        if (k == "hoverStartMS") HOVER_START_MS = v;
        else if (k == "dwellActivateMS") DWELL_ACTIVATE_MS = v;
        else if (k == "hoverLetterMS") HOVER_LETTER_MS = v;
    }
}
static double nowUnix() { return (double)time(nullptr); }
static int session() { return Lexicon::currentSession(nowUnix()); }

static void refreshBank() { g_bank = g_lexicon->topUsed(5, nowUnix()); }
static void flushReinforce() {
    if (!g_pendingReinforce.empty()) {
        g_lexicon->reinforce(g_pendingReinforce, session(), nowUnix());
        g_lexicon->saveLearned(learnedPath());
        refreshBank();
    }
    g_pendingReinforce.clear();
}
static std::string applyCase(const std::string& w) {
    if (!g_shiftPending || w.empty()) return w;
    g_shiftPending = false;
    std::string out = w;
    out[0] = (char)toupper((unsigned char)out[0]);
    return out;
}
static void armShiftAfter(const std::string& p) {
    if (p.find('.') != std::string::npos || p.find('?') != std::string::npos ||
        p.find('!') != std::string::npos) g_shiftPending = true;
}
static void setStatus(const std::wstring& s) { g_status = s; }
static void showCandidates(const std::vector<std::string>& words, int sel) {
    g_candidates.clear();
    for (auto& w : words) g_candidates.push_back({w, 0, 0, 0});
    g_selectedIndex = sel;
    g_candOffset = 0;
    refresh();
}
static void wordSeparatorIfNeeded() {
    if (!g_typed.empty() && g_typed.back() != ' ' && g_typed.back() != '\'') inject(" ");
}
static void fixStandaloneI() {
    size_t n = g_typed.size();
    if (n >= 1 && g_typed[n-1] == 'i' && (n == 1 || g_typed[n-2] == ' ')) {
        eraseN(1); inject("I");
    }
}
static void learnCompletedWord() {
    std::string t = g_typed;
    while (!t.empty() && t.back() == ' ') t.pop_back();
    size_t e = t.size(), s = e;
    while (s > 0 && isalpha((unsigned char)t[s-1])) s--;
    std::string w = t.substr(s, e - s);
    for (auto& c : w) c = (char)tolower((unsigned char)c);
    if (w.size() >= 2 && !g_lexicon->contains(w)) {
        g_lexicon->learn(w, session(), nowUnix());
        g_lexicon->saveLearned(learnedPath());
        refreshBank();
        setStatus(L"learned \"" + widen(w) + L"\"");
    }
}

static std::string performReplace(int lo, int hi, const std::string& word) {
    std::string tail = g_typed.substr(hi);
    eraseN((int)g_typed.size() - lo);
    inject(word + tail);
    return tail;
}

static void selectCandidate(int idx) {
    if (!g_hasCommit || idx < 0 || idx >= (int)g_commit.cands.size()) return;
    g_commit.index = idx;
    std::string word = g_commit.cands[idx];
    if (g_commit.capitalized && !word.empty())
        word[0] = (char)toupper((unsigned char)word[0]);
    std::string text = g_commit.tail.empty() ? word + " " : word;
    eraseN(g_commit.insertedLength + (int)g_commit.tail.size());
    inject(text + g_commit.tail);
    g_commit.insertedLength = (int)text.size();
    g_letterRun.clear();
    g_pendingReinforce = g_commit.cands[idx];
    g_selectedIndex = idx;
    setStatus(widen(word));
    refresh();
}

static void commitGlide(const std::vector<Pt>& path,
                        const std::vector<Emphasis>& emphases = {}) {
    g_letterRun.clear();
    auto cands = g_decoder->decode(path, emphases);
    if (cands.empty() || cands[0].score > g_cfg.maxScoreKeys * g_layout->keyPitch) {
        g_hasCommit = false;
        showCandidates({}, 0);
        setStatus(L"no match - try again");
        return;
    }
    std::string best = cands[0].word;
    std::vector<std::string> names;
    for (auto& c : cands) names.push_back(c.word);

    if (g_replaceLo >= 0) {
        int lo = g_replaceLo, hi = g_replaceHi;
        std::string word = applyCase(best);
        std::string tail = performReplace(lo, hi, word);
        g_commit = {names, 0, (int)word.size(), tail, word != best};
    } else {
        wordSeparatorIfNeeded();
        std::string word = applyCase(best);
        std::string text = word + " ";
        inject(text);
        g_commit = {names, 0, (int)text.size(), "", word != best};
    }
    g_hasCommit = true;
    g_pendingReinforce = best;
    showCandidates(names, 0);
    setStatus(widen(best));
}

static void offerCompletions() {
    if (g_letterRun == "a" || g_letterRun == "i") {
        g_hasCommit = false; showCandidates({}, 0); setStatus(widen(g_letterRun)); return;
    }
    auto comps = g_lexicon->complete(g_letterRun, g_cfg.candidateCount);
    if (comps.empty()) {
        g_hasCommit = false; showCandidates({}, 0); setStatus(widen(g_letterRun)); return;
    }
    std::vector<std::string> names{g_letterRun};
    names.insert(names.end(), comps.begin(), comps.end());
    g_commit = {names, 0, (int)g_letterRun.size(), "", g_letterRunCapitalized};
    g_hasCommit = true;
    g_pendingReinforce.clear();
    showCandidates(names, 0);
    setStatus(widen(g_letterRun));
}

static void insertSpace() {
    learnCompletedWord();
    fixStandaloneI();
    g_letterRun.clear();
    g_hasCommit = false;
    inject(" ");
    showCandidates({}, 0);
    setStatus(L"space");
}
static void spaceTapped() {
    flushReinforce();
    ULONGLONG now = GetTickCount64();
    ULONGLONG last = g_lastSpaceTap;
    if (last && now - last < 450 && !g_typed.empty() && g_typed.back() == ' ') {
        g_hasCommit = false;
        int trailing = 0;
        for (auto it = g_typed.rbegin(); it != g_typed.rend() && *it == ' '; ++it) trailing++;
        eraseN(trailing);
        fixStandaloneI();
        inject(". ");
        armShiftAfter(".");
        showCandidates({}, 0);
        setStatus(L". ");
        return;
    }
    insertSpace();
    g_lastSpaceTap = GetTickCount64();
}
static void punctTapped(int i) {
    flushReinforce();
    if (i == 0) {                                   // shift
        g_shiftPending = !g_shiftPending;
        g_hasCommit = false;
        showCandidates({}, 0);
        setStatus(g_shiftPending ? L"\x21E7 next letter capitalized" : L"");
        return;
    }
    g_hasCommit = false;
    std::string label = PUNCT_CH[i];
    if (label == "'") {
        int trailing = 0;
        for (auto it = g_typed.rbegin(); it != g_typed.rend() && *it == ' '; ++it) trailing++;
        eraseN(trailing);
        inject("'");
        g_letterRun.clear();
        showCandidates({}, 0);
        setStatus(L"'");
        return;
    }
    learnCompletedWord();
    g_letterRun.clear();
    int trailing = 0;
    for (auto it = g_typed.rbegin(); it != g_typed.rend() && *it == ' '; ++it) trailing++;
    eraseN(trailing);
    fixStandaloneI();
    inject(label + " ");
    armShiftAfter(label);
    showCandidates({}, 0);
    setStatus(widen(label));
}

static void deleteTapped() {                        // press; escalation in timer
    g_deleteHeld = true;
    g_deleteSince = GetTickCount64();
    g_deleteRepeats = 0;
    bool midRun = !g_letterRun.empty();
    g_letterRun.clear();
    g_pendingReinforce.clear();
    if (g_hasCommit && !midRun) {
        eraseN(g_commit.insertedLength + (int)g_commit.tail.size());
        if (!g_commit.tail.empty()) inject(g_commit.tail);
        g_hasCommit = false;
        setStatus(L"\x232B word");
    } else {
        g_hasCommit = false;
        eraseN(1);
        setStatus(L"\x232B");
    }
    showCandidates({}, 0);
}

// ------------------------------------------------------------------- input --
static void confine(bool on) {
    if (!on) { ClipCursor(nullptr); return; }
    RECT r; GetWindowRect(g_hwnd, &r);
    InflateRect(&r, -2, -2);
    ClipCursor(&r);
}

static POINT clientCursor();
static bool inRect(const RECT& r, POINT p);
static bool activateControl(POINT c);
static void tapLetter(char ch);
static void backspaceViaDwell();

static void setHoverMode(bool on) {
    g_hoverMode = on;
    g_hoverTracing = false;
    g_hoverPath.clear(); g_hoverDwell.clear();
    g_dwellToken.clear(); g_dwellTargetTime = 0; g_dwellFired = false;
    g_dwellLive = false; g_dwellEngineStart = GetTickCount64();
    g_dwellProgress = 0;
    setStatus(on ? L"hover mode - pause on a letter to start" : L"");
    showCandidates({}, 0);
}

// What the cursor is over, as a stable identity for dwell refractory. The
// toggle itself is absent on purpose: a resting cursor must never dwell the
// user out of their own input mode.
static std::string dwellTokenAt(POINT c) {
    if (inRect(hoverToggleRect(), c)) return "";
    if (inRect(spaceBar(), c)) return "space";
    for (int i = 0; i < 6; i++) if (inRect(punctRect(i), c)) return "punct" + std::to_string(i);
    for (auto& twr : g_typedWordRects)
        if (inRect(twr.r, c)) return "typed" + std::to_string(twr.lo);
    for (size_t i = 0; i < g_chipRects.size(); i++)
        if (g_hasCommit && inRect(g_chipRects[i], c)) return "chip" + std::to_string(i);
    if (inRect(deleteKey(), c)) return "del";
    for (size_t i = 0; i < g_bank.size(); i++)
        if (inRect(bankSlot((int)i, (int)g_bank.size()), c)) return "bank" + std::to_string(i);
    RECT ka = keyArea(); InflateRect(&ka, 6, 6);
    if (inRect(ka, c)) return "key";
    return "";
}

static void finishHoverTrace() {
    g_hoverTracing = false;
    g_hoverPath.clear(); g_hoverDwell.clear();
    g_armStillTotal = -1;
    g_dwellProgress = 0;
    refresh();
}

static double g_hoverStill = 0;

static void hoverTick() {
    if (!g_glideMode || !g_hoverMode) return;
    if (g_tracing || g_deleteHeld || g_draggingPanel) { g_hoverStill = 0; g_dwellProgress = 0; return; }

    const double dt = 0.01;                       // 10ms timer
    POINT c = clientCursor();
    bool moved = std::abs(c.x - g_hoverLast.x) > 1 || std::abs(c.y - g_hoverLast.y) > 1;
    g_hoverStill = moved ? 0 : g_hoverStill + dt;
    g_hoverLast = c;

    if (!g_dwellLive) {                           // grace after activation warp
        if (GetTickCount64() - g_dwellEngineStart < 350) return;
        if (moved) g_dwellLive = true; else return;
    }

    if (g_hoverTracing) {
        if (moved) {
            g_armStillTotal = -1;
            g_hoverPath.push_back(toEngine(c));
            g_hoverDwell.push_back(0);
            g_tracePath = g_hoverPath;            // reuse live-trace drawing
            refresh();
        } else {
            if (!g_hoverDwell.empty()) g_hoverDwell.back() += dt;
            if (g_armStillTotal >= 0) {           // single-letter path
                g_armStillTotal += dt;
                g_dwellPoint = c;
                g_dwellProgress = std::min(1.0, g_armStillTotal * 1000 / HOVER_LETTER_MS);
                refresh();
                if (g_armStillTotal * 1000 >= HOVER_LETTER_MS) {
                    Pt p = toEngine(c);
                    finishHoverTrace();
                    g_tracePath.clear();
                    char ch = g_decoder->decodeTap(p);
                    if (ch) tapLetter(ch);
                    return;
                }
            }
        }
        // spatial commit: exit above the grid (client y smaller = higher)
        RECT ka = keyArea();
        if (c.y < ka.top - (int)COMMIT_EXIT_BUFFER) {
            auto path = g_hoverPath;
            auto dwell = g_hoverDwell;
            finishHoverTrace();
            g_tracePath.clear();
            if (pathLength(path) >= 0.55 * g_layout->keyPitch) {
                auto [cleaned, emphases] = detectEmphases(path, dwell, *g_layout, g_cfg);
                commitGlide(cleaned, emphases);
            }
        }
        return;
    }

    // TRAVELING
    std::string token = dwellTokenAt(c);
    if (moved || token != g_dwellToken) {
        g_dwellToken = token;
        g_dwellTargetTime = 0;
        g_dwellFired = false;
        if (g_dwellProgress != 0) { g_dwellProgress = 0; refresh(); }
        return;
    }
    if (token.empty()) { if (g_dwellProgress != 0) { g_dwellProgress = 0; refresh(); } return; }

    g_dwellTargetTime += dt;
    double ms = g_dwellTargetTime * 1000;

    if (token == "key") {
        g_dwellPoint = c;
        g_dwellProgress = std::min(1.0, ms / HOVER_START_MS);
        refresh();
        if (ms >= HOVER_START_MS) {
            g_hoverTracing = true;
            g_hoverPath = {toEngine(c)};
            g_hoverDwell = {0};
            g_armStillTotal = g_dwellTargetTime;
            g_hoverStill = 0;
            g_dwellToken.clear(); g_dwellTargetTime = 0;
            g_dwellProgress = 0;
            setStatus(L"tracing - sweep, exit upward to type");
            showCandidates({}, 0);
        }
        return;
    }

    if (g_dwellFired) {
        if (token == "del" && ms >= 500) { g_dwellTargetTime = 0; backspaceViaDwell(); }
        return;
    }
    g_dwellPoint = c;
    g_dwellProgress = std::min(1.0, ms / DWELL_ACTIVATE_MS);
    refresh();
    if (ms >= DWELL_ACTIVATE_MS) {
        g_dwellFired = true;
        g_dwellProgress = 0;
        activateControl(c);
    }
}

static void toggleGlide() {
    g_glideMode = !g_glideMode;
    if (g_glideMode) {
        g_typed.clear(); g_letterRun.clear(); g_hasCommit = false; g_shiftPending = false;
        clearReplaceTarget();
        refreshBank();
        ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);
        GetCursorPos(&g_savedCursor);
        RECT r; GetWindowRect(g_hwnd, &r);
        SetCursorPos((r.left + r.right) / 2, (r.top + r.bottom) / 2);
        confine(true);
        g_dwellLive = false;
        g_dwellEngineStart = GetTickCount64();
        setStatus(L"trace a word");
        showCandidates({}, 0);
    } else {
        flushReinforce();
        confine(false);
        ShowWindow(g_hwnd, SW_HIDE);
        SetCursorPos(g_savedCursor.x, g_savedCursor.y);
    }
    refresh();
}

static POINT clientCursor() {
    POINT p; GetCursorPos(&p); ScreenToClient(g_hwnd, &p); return p;
}
static bool inRect(const RECT& r, POINT p) { return PtInRect(&r, p) != 0; }

static void beginTrace() {
    POINT c = clientCursor();
    if (c.y < GRABBER_H) {                          // grabber -> drag the panel
        g_draggingPanel = true;
        POINT sc; GetCursorPos(&sc);
        RECT r; GetWindowRect(g_hwnd, &r);
        g_dragOffset = {sc.x - r.left, sc.y - r.top};
        confine(false);
        return;
    }
    // chip press bookkeeping for long-press-forget
    g_chipPressedWord.clear();
    for (size_t i = 0; i < g_chipRects.size(); i++)
        if (g_hasCommit && inRect(g_chipRects[i], c) && i < g_commit.cands.size()) {
            g_chipPressedWord = g_commit.cands[i];
            g_chipPressedAt = GetTickCount64();
        }
    for (size_t i = 0; i < g_bank.size(); i++)
        if (inRect(bankSlot((int)i, (int)g_bank.size()), c)) {
            g_chipPressedWord = g_bank[i];
            g_chipPressedAt = GetTickCount64();
        }

    if (inRect(deleteKey(), c)) { deleteTapped(); return; }

    g_tracing = true;
    g_tracePath = {toEngine(c)};
    g_traceDwell = {0};
}

static void setHoverMode(bool on);

static void tapLetter(char ch) {
    if (g_replaceLo >= 0) {
        std::string t = applyCase(std::string(1, ch));
        performReplace(g_replaceLo, g_replaceHi, t);
        g_hasCommit = false;
        setStatus(widen(t));
    } else {
        if (g_letterRun.empty()) g_letterRunCapitalized = g_shiftPending;
        inject(applyCase(std::string(1, ch)));
        g_letterRun += ch;
        offerCompletions();
    }
}

static void backspaceViaDwell() {
    bool midRun = !g_letterRun.empty();
    g_letterRun.clear();
    g_pendingReinforce.clear();
    if (g_hasCommit && !midRun) {
        eraseN(g_commit.insertedLength + (int)g_commit.tail.size());
        if (!g_commit.tail.empty()) inject(g_commit.tail);
        g_hasCommit = false;
        setStatus(L"\x232B word");
    } else {
        g_hasCommit = false;
        eraseN(1);
        setStatus(L"\x232B");
    }
    showCandidates({}, 0);
}

// Shared control dispatch for click-taps and dwell fires: everything on the
// panel that is not a letter key.
static bool activateControl(POINT c) {
    if (inRect(hoverToggleRect(), c)) { setHoverMode(!g_hoverMode); return true; }
    if (inRect(spaceBar(), c)) { spaceTapped(); return true; }
    for (int i = 0; i < 6; i++) if (inRect(punctRect(i), c)) { punctTapped(i); return true; }
    for (auto& twr : g_typedWordRects)
        if (inRect(twr.r, c)) {
            flushReinforce();
            g_letterRun.clear(); g_hasCommit = false;
            if (g_replaceLo == twr.lo) { clearReplaceTarget(); setStatus(L""); }
            else {
                g_replaceLo = twr.lo; g_replaceHi = twr.hi;
                setStatus(L"glide to replace");
            }
            showCandidates({}, 0);
            refresh();
            return true;
        }
    for (size_t i = 0; i < g_chipRects.size(); i++)
        if (g_hasCommit && inRect(g_chipRects[i], c)) { selectCandidate((int)i); return true; }
    if (inRect(deleteKey(), c)) { backspaceViaDwell(); return true; }
    for (size_t i = 0; i < g_bank.size(); i++)
        if (inRect(bankSlot((int)i, (int)g_bank.size()), c)) {
            std::string word = applyCase(g_bank[i]);
            g_letterRun.clear();
            if (g_replaceLo >= 0) performReplace(g_replaceLo, g_replaceHi, word);
            else { wordSeparatorIfNeeded(); inject(word + " "); }
            g_lexicon->reinforce(g_bank[i], session(), nowUnix());
            g_lexicon->saveLearned(learnedPath());
            g_hasCommit = false;
            refreshBank();
            showCandidates({}, 0);
            setStatus(widen(word));
            return true;
        }
    return false;
}

static void endTrace() {
    if (g_draggingPanel) { g_draggingPanel = false; confine(true); return; }
    if (g_deleteHeld) { g_deleteHeld = false; refresh(); return; }
    if (!g_tracing) return;
    g_tracing = false;
    auto path = g_tracePath;
    auto dwellCopy = g_traceDwell;
    g_tracePath.clear();
    g_traceDwell.clear();
    flushReinforce();

    POINT c = clientCursor();
    if (pathLength(path) < 0.55 * g_layout->keyPitch) {   // a tap
        if (!g_chipPressedWord.empty() && GetTickCount64() - g_chipPressedAt > 700 &&
            g_lexicon->isLearned(g_chipPressedWord)) {     // long-press = forget
            g_lexicon->forget(g_chipPressedWord);
            g_lexicon->saveLearned(learnedPath());
            g_hasCommit = false;
            refreshBank();
            showCandidates({}, 0);
            setStatus(L"forgot \"" + widen(g_chipPressedWord) + L"\"");
            g_chipPressedWord.clear();
            return;
        }
        g_chipPressedWord.clear();
        if (activateControl(c)) return;
        RECT ka = keyArea();
        InflateRect(&ka, 6, 6);
        if (inRect(ka, c)) {
            char ch = g_decoder->decodeTap(toEngine(c));
            if (ch) tapLetter(ch);
        }
        return;
    }
    g_chipPressedWord.clear();
    auto [cleaned, emphases] = detectEmphases(path, dwellCopy, *g_layout, g_cfg);
    commitGlide(cleaned, emphases);
}

// hooks ----------------------------------------------------------------------
static HHOOK g_mouseHook, g_keyHook;

static LRESULT CALLBACK MouseProc(int code, WPARAM w, LPARAM l) {
    if (code == HC_ACTION && g_glideMode) {
        auto* info = (MSLLHOOKSTRUCT*)l;
        if (info->dwExtraInfo != INJECT_TAG) {
            switch (w) {
            case WM_LBUTTONDOWN: beginTrace(); return 1;
            case WM_LBUTTONUP: endTrace(); return 1;
            case WM_RBUTTONDOWN: case WM_RBUTTONUP: return 1;
            case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL: {
                short delta = GET_WHEEL_DELTA_WPARAM(info->mouseData);
                g_candOffset += (w == WM_MOUSEHWHEEL ? delta : -delta) * 0.5;
                if (g_candOffset < 0) g_candOffset = 0;
                refresh();
                return 1;
            }
            }
        }
    }
    return CallNextHookEx(g_mouseHook, code, w, l);
}

static LRESULT CALLBACK KeyProc(int code, WPARAM w, LPARAM l) {
    if (code == HC_ACTION) {
        auto* info = (KBDLLHOOKSTRUCT*)l;
        bool down = (w == WM_KEYDOWN || w == WM_SYSKEYDOWN);
        if (down && info->dwExtraInfo != INJECT_TAG) {
            bool ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
            bool alt = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
            if (ctrl && alt && info->vkCode == VK_SPACE) {
                PostMessageW(g_hwnd, WM_APP + 1, 0, 0);
                return 1;
            }
            if (g_glideMode && g_hasCommit && !ctrl && !alt &&
                (info->vkCode == VK_LEFT || info->vkCode == VK_RIGHT)) {
                int n = (int)g_commit.cands.size();
                int dir = info->vkCode == VK_RIGHT ? 1 : -1;
                PostMessageW(g_hwnd, WM_APP + 2, (WPARAM)(((g_commit.index + dir) % n + n) % n), 0);
                return 1;
            }
        }
    }
    return CallNextHookEx(g_keyHook, code, w, l);
}

// ------------------------------------------------------------------- paint --
static void paint(HDC dc) {
    RECT rc = {0, 0, panelW(), panelH()};
    HDC mem = CreateCompatibleDC(dc);
    HBITMAP bmp = CreateCompatibleBitmap(dc, rc.right, rc.bottom);
    HGDIOBJ old = SelectObject(mem, bmp);
    SetBkMode(mem, TRANSPARENT);

    HBRUSH bg = CreateSolidBrush(RGB(23, 23, 25));
    FillRect(mem, &rc, bg); DeleteObject(bg);

    HFONT fKey = CreateFontW(-(int)(g_layout->keyPitch * 0.38), 0,0,0, FW_MEDIUM, 0,0,0, DEFAULT_CHARSET,
                             0,0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HFONT fChip = CreateFontW(-16, 0,0,0, FW_SEMIBOLD, 0,0,0, DEFAULT_CHARSET, 0,0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HFONT fSmall = CreateFontW(-13, 0,0,0, FW_NORMAL, 0,0,0, DEFAULT_CHARSET, 0,0, CLEARTYPE_QUALITY, 0, L"Segoe UI");

    auto fill = [&](RECT r, COLORREF col) {
        HBRUSH b = CreateSolidBrush(col);
        HPEN p = (HPEN)GetStockObject(NULL_PEN);
        HGDIOBJ ob = SelectObject(mem, b); HGDIOBJ op = SelectObject(mem, p);
        RoundRect(mem, r.left, r.top, r.right, r.bottom, 10, 10);
        SelectObject(mem, ob); SelectObject(mem, op);
        DeleteObject(b);
    };
    auto label = [&](RECT r, const std::wstring& s, COLORREF col, HFONT f) {
        HGDIOBJ of = SelectObject(mem, f);
        SetTextColor(mem, col);
        DrawTextW(mem, s.c_str(), -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(mem, of);
    };

    // grabber pill
    RECT pill = {panelW()/2 - 18, 5, panelW()/2 + 18, 10};
    fill(pill, RGB(110,110,115));

    // typed bar: newest words laid right-to-left, words are chips
    RECT tb = textBar();
    fill(tb, RGB(36,36,40));
    g_typedWordRects.clear();
    {
        HGDIOBJ of = SelectObject(mem, fSmall);
        int x = tb.right - 8;
        size_t i = g_typed.size();
        while (i > 0 && x > tb.left + 8) {
            size_t e = i;
            while (e > 0 && !isalpha((unsigned char)g_typed[e-1])) e--;
            size_t s = e;
            while (s > 0 && isalpha((unsigned char)g_typed[s-1])) s--;
            if (e < i) {
                std::wstring glue = widen(g_typed.substr(e, i - e));
                SIZE sz; GetTextExtentPoint32W(mem, glue.c_str(), (int)glue.size(), &sz);
                x -= sz.cx;
                SetTextColor(mem, RGB(140,140,145));
                TextOutW(mem, x, (tb.top + tb.bottom)/2 - sz.cy/2, glue.c_str(), (int)glue.size());
            }
            if (e > s) {
                std::wstring word = widen(g_typed.substr(s, e - s));
                SIZE sz; GetTextExtentPoint32W(mem, word.c_str(), (int)word.size(), &sz);
                RECT chip = {x - sz.cx - 12, tb.top + 3, x, tb.bottom - 3};
                if (chip.left < tb.left + 4) break;
                bool marked = ((int)s == g_replaceLo);
                fill(chip, marked ? RGB(214,116,50) : RGB(58,58,64));
                label(chip, word, marked ? RGB(255,255,255) : RGB(205,205,210), fSmall);
                g_typedWordRects.push_back({chip, (int)s, (int)e});
                x = chip.left - 4;
            }
            i = s;
        }
        SelectObject(mem, of);
    }

    // candidate strip (scrollable, clipped)
    RECT strip = stripRect();
    g_chipRects.clear();
    if (g_candidates.empty()) {
        RECT r = strip; r.left += 6;
        HGDIOBJ of = SelectObject(mem, fSmall);
        SetTextColor(mem, RGB(140,140,145));
        DrawTextW(mem, g_status.c_str(), -1, &r, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        SelectObject(mem, of);
    } else {
        IntersectClipRect(mem, strip.left, strip.top, strip.right, strip.bottom);
        double x = strip.left + 4 - g_candOffset;
        HGDIOBJ of = SelectObject(mem, fChip);
        for (size_t i = 0; i < g_candidates.size(); i++) {
            std::wstring w = widen(g_candidates[i].word);
            SIZE sz; GetTextExtentPoint32W(mem, w.c_str(), (int)w.size(), &sz);
            RECT chip = {(LONG)x, strip.top + 6, (LONG)x + sz.cx + 24, strip.bottom - 6};
            bool sel = ((int)i == g_selectedIndex);
            if (chip.right > strip.left && chip.left < strip.right) {
                fill(chip, sel ? RGB(61,128,242) : RGB(51,51,56));
                label(chip, w, sel ? RGB(255,255,255) : RGB(170,170,178), fChip);
                g_chipRects.push_back(chip);
            } else g_chipRects.push_back({0,0,0,0});
            x = chip.right + 10;
        }
        SelectObject(mem, of);
        SelectClipRgn(mem, nullptr);
    }

    // letter keys with hover highlight
    RECT ka = keyArea();
    POINT cur = clientCursor();
    char hover = (g_glideMode && inRect(ka, cur)) ? g_decoder->decodeTap(toEngine(cur)) : 0;
    for (auto& kv : g_layout->keys) {
        POINT c = keyCenterClient(kv.first);
        int pw = (int)g_layout->keyPitch, ph = (int)g_layout->rowPitch;
        RECT r = {c.x - pw/2 + 2, c.y - ph/2 + 2, c.x + pw/2 - 2, c.y + ph/2 - 2};
        fill(r, kv.first == hover ? RGB(61,128,242) : RGB(56,56,62));
        wchar_t up[2] = {(wchar_t)toupper(kv.first), 0};
        label(r, up, RGB(210,210,215), fKey);
    }
    RECT dk = deleteKey();
    fill(dk, g_deleteHeld ? RGB(200,72,72) : RGB(76,76,84));
    label(dk, L"\x232B", RGB(215,215,220), fKey);

    // space row + punctuation
    RECT sp = spaceBar();
    fill(sp, RGB(76,76,84));
    label(sp, L"space", RGB(160,160,168), fSmall);
    for (int i = 0; i < 6; i++) {
        RECT r = punctRect(i);
        bool shiftKey = (i == 0);
        fill(r, shiftKey && g_shiftPending ? RGB(61,128,242) : RGB(66,66,74));
        label(r, PUNCT[i], shiftKey && g_shiftPending ? RGB(255,255,255) : RGB(185,185,192), fKey);
    }

    // hover toggle
    {
        RECT r = hoverToggleRect();
        fill(r, g_hoverMode ? RGB(61, 158, 107) : RGB(61, 61, 68));
        label(r, L"hover", g_hoverMode ? RGB(255,255,255) : RGB(160,160,168), fSmall);
    }
    // word bank
    for (size_t i = 0; i < g_bank.size(); i++) {
        RECT r = bankSlot((int)i, (int)g_bank.size());
        fill(r, RGB(48,48,54));
        label(r, widen(g_bank[i]), RGB(200,200,206), fSmall);
    }

    // hover-tracing grid tint
    if (g_hoverTracing) {
        RECT kb = keyArea();
        InflateRect(&kb, 3, 3);
        HPEN pen = CreatePen(PS_SOLID, 2, RGB(77, 153, 255));
        HGDIOBJ op = SelectObject(mem, pen);
        HGDIOBJ ob = SelectObject(mem, GetStockObject(NULL_BRUSH));
        RoundRect(mem, kb.left, kb.top, kb.right, kb.bottom, 8, 8);
        SelectObject(mem, op); SelectObject(mem, ob);
        DeleteObject(pen);
    }
    // dwell progress ring
    if (g_dwellProgress > 0.03) {
        int r = 14;
        HPEN bgp = CreatePen(PS_SOLID, 4, RGB(60, 60, 66));
        HGDIOBJ op = SelectObject(mem, bgp);
        HGDIOBJ ob = SelectObject(mem, GetStockObject(NULL_BRUSH));
        Ellipse(mem, g_dwellPoint.x - r, g_dwellPoint.y - r, g_dwellPoint.x + r, g_dwellPoint.y + r);
        SelectObject(mem, op); DeleteObject(bgp);
        HPEN arcp = CreatePen(PS_SOLID, 4, RGB(89, 204, 128));
        SelectObject(mem, arcp);
        double a = g_dwellProgress * 6.28318;
        Arc(mem, g_dwellPoint.x - r, g_dwellPoint.y - r, g_dwellPoint.x + r, g_dwellPoint.y + r,
            g_dwellPoint.x + (int)(100 * sin(a)), g_dwellPoint.y - (int)(100 * cos(a)),
            g_dwellPoint.x, g_dwellPoint.y - 100);
        SelectObject(mem, op); SelectObject(mem, ob);
        DeleteObject(arcp);
    }
    // live trace
    if (g_tracePath.size() > 1) {
        HPEN pen = CreatePen(PS_SOLID, 4, RGB(102,204,255));
        HGDIOBJ op = SelectObject(mem, pen);
        RECT kr = keyArea();
        MoveToEx(mem, kr.left + (int)g_tracePath[0].x, kr.bottom - (int)g_tracePath[0].y, nullptr);
        for (size_t i = 1; i < g_tracePath.size(); i++)
            LineTo(mem, kr.left + (int)g_tracePath[i].x, kr.bottom - (int)g_tracePath[i].y);
        SelectObject(mem, op);
        DeleteObject(pen);
    }

    BitBlt(dc, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
    DeleteObject(fKey); DeleteObject(fChip); DeleteObject(fSmall);
    SelectObject(mem, old); DeleteObject(bmp); DeleteDC(mem);
}

// ------------------------------------------------------------------- shell --
static std::string appDataDir() {
    wchar_t path[MAX_PATH];
    SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, path);
    std::wstring d = std::wstring(path) + L"\\TrackpadTyping";
    CreateDirectoryW(d.c_str(), nullptr);
    return std::string(d.begin(), d.end());
}
static std::string learnedPath() { return appDataDir() + "\\learned.txt"; }

// ---------------------------------------------------------- settings UI --
static HWND g_settingsWnd = nullptr;
static HWND g_bars[3], g_vals[3];
static const wchar_t* SET_LABELS[3] = {
    L"Start a word (pause on a letter)",
    L"Press a button (suggestions, space, delete...)",
    L"Type a single letter (rest on one key)",
};
static double* SET_TARGETS[3] = {&HOVER_START_MS, &DWELL_ACTIVATE_MS, &HOVER_LETTER_MS};
static const int SET_MIN[3] = {200, 300, 600};
static const int SET_MAX[3] = {1500, 2000, 3000};

static void settingsUpdateLabel(int i) {
    wchar_t buf[32];
    wsprintfW(buf, L"%d ms", (int)*SET_TARGETS[i]);
    SetWindowTextW(g_vals[i], buf);
}

static LRESULT CALLBACK SettingsProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_HSCROLL:
        for (int i = 0; i < 3; i++)
            if ((HWND)l == g_bars[i]) {
                *SET_TARGETS[i] = (double)SendMessageW(g_bars[i], TBM_GETPOS, 0, 0);
                settingsUpdateLabel(i);
                saveSettings();
            }
        return 0;
    case WM_COMMAND:
        if (LOWORD(w) == 100) {                      // reset button
            HOVER_START_MS = 450; DWELL_ACTIVATE_MS = 650; HOVER_LETTER_MS = 1100;
            for (int i = 0; i < 3; i++) {
                SendMessageW(g_bars[i], TBM_SETPOS, TRUE, (LPARAM)*SET_TARGETS[i]);
                settingsUpdateLabel(i);
            }
            saveSettings();
        }
        return 0;
    case WM_CLOSE: ShowWindow(h, SW_HIDE); return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static void showSettings(HINSTANCE inst) {
    if (!g_settingsWnd) {
        WNDCLASSW wc = {};
        wc.lpfnWndProc = SettingsProc;
        wc.hInstance = inst;
        wc.lpszClassName = L"TrackpadTypingSettings";
        wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        RegisterClassW(&wc);
        g_settingsWnd = CreateWindowExW(WS_EX_TOPMOST, wc.lpszClassName,
            L"TrackpadTyping - Dwell Settings",
            WS_CAPTION | WS_SYSMENU, 200, 200, 460, 300,
            nullptr, nullptr, inst, nullptr);
        int y = 10;
        for (int i = 0; i < 3; i++) {
            CreateWindowW(L"STATIC", SET_LABELS[i], WS_CHILD | WS_VISIBLE,
                          15, y, 320, 18, g_settingsWnd, nullptr, inst, nullptr);
            g_vals[i] = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_RIGHT,
                                      350, y, 80, 18, g_settingsWnd, nullptr, inst, nullptr);
            g_bars[i] = CreateWindowW(TRACKBAR_CLASSW, L"",
                                      WS_CHILD | WS_VISIBLE | TBS_HORZ,
                                      15, y + 20, 415, 30, g_settingsWnd, nullptr, inst, nullptr);
            SendMessageW(g_bars[i], TBM_SETRANGE, TRUE, MAKELPARAM(SET_MIN[i], SET_MAX[i]));
            SendMessageW(g_bars[i], TBM_SETPOS, TRUE, (LPARAM)*SET_TARGETS[i]);
            settingsUpdateLabel(i);
            y += 62;
        }
        CreateWindowW(L"BUTTON", L"Reset to defaults", WS_CHILD | WS_VISIBLE,
                      15, y + 4, 150, 28, g_settingsWnd, (HMENU)100, inst, nullptr);
    }
    ShowWindow(g_settingsWnd, SW_SHOW);
    SetForegroundWindow(g_settingsWnd);
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        paint(dc);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_APP + 1: toggleGlide(); return 0;
    case WM_APP + 2: selectCandidate((int)w); return 0;
    case WM_TIMER:
        if (g_draggingPanel) {
            POINT sc; GetCursorPos(&sc);
            SetWindowPos(h, HWND_TOPMOST, sc.x - g_dragOffset.x, sc.y - g_dragOffset.y,
                         0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
        } else if (g_tracing) {
            Pt p = toEngine(clientCursor());
            if (g_tracePath.empty() || g_tracePath.back().dist(p) > 0.5) {
                g_tracePath.push_back(p);
                g_traceDwell.push_back(0);
                refresh();
            } else if (!g_traceDwell.empty()) {
                g_traceDwell.back() += 0.01;
            }
        } else if (g_deleteHeld) {
            double held = (GetTickCount64() - g_deleteSince) / 1000.0;
            if (held > 0.40) {
                double active = held - 0.40;
                int due = active < 2.0 ? (int)(active / 0.125) : 16 + (int)((active - 2.0) / 0.30);
                while (g_deleteRepeats < due) {
                    g_deleteRepeats++;
                    if (g_deleteRepeats <= 16) eraseN(1); else eraseWord();
                }
            }
        } else if (g_glideMode) {
            hoverTick();
            refresh();                              // hover highlight
        }
        return 0;
    case WM_APP + 3:                                // tray icon events
        if (l == WM_RBUTTONUP || l == WM_LBUTTONUP) {
            POINT pt; GetCursorPos(&pt);
            HMENU menu = CreatePopupMenu();
            AppendMenuW(menu, MF_STRING, 10, g_glideMode ? L"Hide keyboard" : L"Show keyboard (Ctrl+Alt+Space)");
            AppendMenuW(menu, MF_STRING, 12, L"Dwell settings...");
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            AppendMenuW(menu, MF_STRING, 11, L"Quit TrackpadTyping");
            SetForegroundWindow(h);
            int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, h, nullptr);
            DestroyMenu(menu);
            if (cmd == 10) toggleGlide();
            if (cmd == 12) showSettings((HINSTANCE)GetWindowLongPtrW(h, GWLP_HINSTANCE));
            if (cmd == 11) DestroyWindow(h);
        }
        return 0;
    case WM_DESTROY:
        Shell_NotifyIconW(NIM_DELETE, &g_tray);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
    // Single instance: a second launch (double-click twice) would stack
    // low-level hooks and fight over the cursor.
    CreateMutexW(nullptr, TRUE, L"TrackpadTypingSingleInstance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(nullptr, L"TrackpadTyping is already running.\n"
                    L"Press Ctrl+Alt+Space to show the keyboard.",
                    L"TrackpadTyping", MB_ICONINFORMATION);
        return 0;
    }

    INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_BAR_CLASSES};
    InitCommonControlsEx(&icc);
    loadSettings();

    static KeyboardLayout layout(44.0, 1.35);
    g_layout = &layout;

    char exePath[MAX_PATH];
    GetModuleFileNameA(nullptr, exePath, MAX_PATH);
    std::string dir(exePath);
    dir = dir.substr(0, dir.find_last_of("\\/"));
    static Lexicon lexicon(g_cfg, dir + "\\lexicon-en.txt", {}, {});
    if (lexicon.size() < 1000) {
        MessageBoxW(nullptr, L"lexicon-en.txt not found next to the exe.",
                    L"TrackpadTyping", MB_ICONERROR);
        return 1;
    }
    lexicon.loadLearned(learnedPath());
    g_lexicon = &lexicon;
    static Decoder decoder(layout, lexicon, g_cfg);
    g_decoder = &decoder;

    WNDCLASSW wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.lpszClassName = L"TrackpadTypingPanel";
    wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_ARROW);
    RegisterClassW(&wc);

    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    g_hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                             wc.lpszClassName, L"TrackpadTyping", WS_POPUP,
                             sw/2 - panelW()/2, sh - panelH() - 60, panelW(), panelH(),
                             nullptr, nullptr, inst, nullptr);

    g_mouseHook = SetWindowsHookExW(WH_MOUSE_LL, MouseProc, inst, 0);
    g_keyHook = SetWindowsHookExW(WH_KEYBOARD_LL, KeyProc, inst, 0);
    SetTimer(g_hwnd, 1, 10, nullptr);               // trace sampling / repeats / hover

    // Tray icon: the only visible sign the app is running while the keyboard
    // is hidden, and the only way to quit it without Task Manager.
    g_tray.cbSize = sizeof(g_tray);
    g_tray.hWnd = g_hwnd;
    g_tray.uID = 1;
    g_tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_tray.uCallbackMessage = WM_APP + 3;
    g_tray.hIcon = LoadIconW(nullptr, (LPCWSTR)IDI_APPLICATION);
    lstrcpyW(g_tray.szTip, L"TrackpadTyping - Ctrl+Alt+Space");
    Shell_NotifyIconW(NIM_ADD, &g_tray);

    MessageBoxW(nullptr,
        L"TrackpadTyping is running (see the tray icon near the clock).\n\n"
        L"1. Click into any text field\n"
        L"2. Press Ctrl+Alt+Space to show the keyboard\n"
        L"3. Click-and-hold, sweep through a word's letters, release\n\n"
        L"Right-click the tray icon to quit.",
        L"TrackpadTyping", MB_ICONINFORMATION);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    UnhookWindowsHookEx(g_mouseHook);
    UnhookWindowsHookEx(g_keyHook);
    return 0;
}
