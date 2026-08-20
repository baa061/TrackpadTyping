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
static RECT bankSlot(int i, int n) {
    int top = panelH() - BANK_H + 2;
    int w = (panelW() - MARGIN * 2) / (n > 0 ? n : 1);
    return {MARGIN + i * w + 3, top, MARGIN + (i + 1) * w - 3, top + BANK_H - 8};
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

static void commitGlide(const std::vector<Pt>& path) {
    g_letterRun.clear();
    auto cands = g_decoder->decode(path);
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
}

static void endTrace() {
    if (g_draggingPanel) { g_draggingPanel = false; confine(true); return; }
    if (g_deleteHeld) { g_deleteHeld = false; refresh(); return; }
    if (!g_tracing) return;
    g_tracing = false;
    auto path = g_tracePath;
    g_tracePath.clear();
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
        if (inRect(spaceBar(), c)) { spaceTapped(); return; }
        for (int i = 0; i < 6; i++) if (inRect(punctRect(i), c)) { punctTapped(i); return; }
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
                return;
            }
        for (size_t i = 0; i < g_chipRects.size(); i++)
            if (g_hasCommit && inRect(g_chipRects[i], c)) { selectCandidate((int)i); return; }
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
                return;
            }
        RECT ka = keyArea();
        InflateRect(&ka, 6, 6);
        if (inRect(ka, c)) {
            char ch = g_decoder->decodeTap(toEngine(c));
            if (ch) {
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
        }
        return;
    }
    g_chipPressedWord.clear();
    commitGlide(path);
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

    // word bank
    for (size_t i = 0; i < g_bank.size(); i++) {
        RECT r = bankSlot((int)i, (int)g_bank.size());
        fill(r, RGB(48,48,54));
        label(r, widen(g_bank[i]), RGB(200,200,206), fSmall);
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
                refresh();
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
        } else if (g_glideMode) refresh();          // hover highlight
        return 0;
    case WM_APP + 3:                                // tray icon events
        if (l == WM_RBUTTONUP || l == WM_LBUTTONUP) {
            POINT pt; GetCursorPos(&pt);
            HMENU menu = CreatePopupMenu();
            AppendMenuW(menu, MF_STRING, 10, g_glideMode ? L"Hide keyboard" : L"Show keyboard (Ctrl+Alt+Space)");
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            AppendMenuW(menu, MF_STRING, 11, L"Quit TrackpadTyping");
            SetForegroundWindow(h);
            int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, h, nullptr);
            DestroyMenu(menu);
            if (cmd == 10) toggleGlide();
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
