// TrackpadTyping engine — portable core of the glide-typing recognizer.
// Direct port of the Swift implementation (Geometry/KeyboardLayout/Lexicon/
// Decoder). No platform dependencies: the Win32 shell and the macOS-hosted
// parity tests both compile against exactly this code.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

namespace tpt {

struct Pt {
    double x = 0, y = 0;
    Pt operator-(const Pt& o) const { return {x - o.x, y - o.y}; }
    Pt operator+(const Pt& o) const { return {x + o.x, y + o.y}; }
    Pt operator*(double s) const { return {x * s, y * s}; }
    double length() const { return std::sqrt(x * x + y * y); }
    double dist(const Pt& o) const { return (*this - o).length(); }
};

// ---------------------------------------------------------------- geometry --
inline double pathLength(const std::vector<Pt>& p) {
    double t = 0;
    for (size_t i = 1; i < p.size(); i++) t += p[i].dist(p[i - 1]);
    return t;
}

inline std::vector<Pt> resample(const std::vector<Pt>& pts, int n) {
    if (n <= 1 || pts.empty()) return pts.empty() ? std::vector<Pt>{} : std::vector<Pt>{pts[0]};
    if (pts.size() == 1) return std::vector<Pt>(n, pts[0]);
    double total = pathLength(pts);
    if (total < 1e-9) return std::vector<Pt>(n, pts[0]);

    double step = total / (n - 1);
    std::vector<Pt> out{pts[0]};
    out.reserve(n);
    size_t src = 1;
    Pt cur = pts[0];
    double remaining = step;
    while ((int)out.size() < n && src < pts.size()) {
        double seg = cur.dist(pts[src]);
        if (seg < remaining) {
            remaining -= seg;
            cur = pts[src++];
        } else {
            double t = seg > 1e-12 ? remaining / seg : 0;
            cur = cur + (pts[src] - cur) * t;
            out.push_back(cur);
            remaining = step;
        }
    }
    while ((int)out.size() < n) out.push_back(pts.back());
    return out;
}

inline Pt centroid(const std::vector<Pt>& pts) {
    Pt c;
    if (pts.empty()) return c;
    for (auto& p : pts) { c.x += p.x; c.y += p.y; }
    c.x /= pts.size(); c.y /= pts.size();
    return c;
}

inline std::vector<Pt> normalizeShape(const std::vector<Pt>& pts, double size) {
    if (pts.empty()) return {};
    double minX = 1e300, maxX = -1e300, minY = 1e300, maxY = -1e300;
    for (auto& p : pts) {
        minX = std::min(minX, p.x); maxX = std::max(maxX, p.x);
        minY = std::min(minY, p.y); maxY = std::max(maxY, p.y);
    }
    double span = std::max(maxX - minX, maxY - minY);
    double scale = span > 1e-6 ? size / span : 0;
    Pt c = centroid(pts);
    std::vector<Pt> out;
    out.reserve(pts.size());
    for (auto& p : pts) out.push_back({(p.x - c.x) * scale, (p.y - c.y) * scale});
    return out;
}

// ------------------------------------------------------------------ layout --
struct KeyboardLayout {
    double keyPitch, rowPitch, width, height;
    std::map<char, Pt> keys;

    KeyboardLayout(double pitch, double rowRatio) : keyPitch(pitch), rowPitch(pitch * rowRatio) {
        width = pitch * 10;
        height = rowPitch * 3;
        const char* rows[3] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"};
        const double stagger[3] = {0.0, 0.25, 0.75};
        for (int r = 0; r < 3; r++) {
            double y = height - rowPitch * (r + 0.5);
            for (int c = 0; rows[r][c]; c++)
                keys[rows[r][c]] = {pitch * (c + 0.5 + stagger[r]), y};
        }
    }

    std::vector<char> lettersNear(const Pt& p, double radius) const {
        std::vector<std::pair<double, char>> hits;
        for (auto& [ch, kp] : keys) {
            double d = kp.dist(p);
            if (d <= radius) hits.push_back({d, ch});
        }
        std::sort(hits.begin(), hits.end());
        std::vector<char> out;
        for (auto& [d, ch] : hits) out.push_back(ch);
        return out;
    }

    char nearestLetter(const Pt& p) const {
        char best = 0; double bd = 1e300;
        for (auto& [ch, kp] : keys) {
            double d = kp.dist(p);
            if (d < bd) { bd = d; best = ch; }
        }
        return best;
    }

    // Ideal path through a word's key centres; consecutive repeats collapse.
    bool templateFor(const std::string& w, std::vector<Pt>& out) const {
        out.clear();
        char last = 0;
        for (char ch : w) {
            auto it = keys.find(ch);
            if (it == keys.end()) {
                if (ch == '\'') continue;          // apostrophes are silent
                return false;
            }
            if (ch != last) out.push_back(it->second);
            last = ch;
        }
        return !out.empty();
    }
};

// ------------------------------------------------------------------ config --
struct Config {
    int resampleCount = 64;
    double shapeWeight = 1.0, locationWeight = 1.0;
    double priorWeightKeys = 0.07;
    double endpointRadiusKeys = 1.6;
    double lengthRatioMin = 0.35, lengthRatioMax = 2.80;
    int candidateCount = 8;
    double maxScoreKeys = 3.5;
    double fallbackRank = 60000, fallbackPenaltyKeys = 1.6;
    int rescoreCount = 100;
    double dtwBlend = 0.75, dtwBandFraction = 0.08;
    bool endWeighting = true;
    int smoothingPasses = 2;
    double midFallbackPenaltyKeys = 0.4;   // real corpus words beyond core
    double deepTierMarginKeys = 0.35;
    double deepSlotMarginKeys = 2.5;
    double endpointAnchorWeight = 0.3;     // raw first/last point distances
    double pauseMinMS = 180, pauseMaxMS = 1200;
    double loopMinTurn = 5.0;
    double emphasisRadiusKeys = 0.8;
    double emphasisMissPenaltyKeys = 1.5;
    double emphasisPositionTolerance = 0.30;
};

/// One deliberately-marked letter in a trace (pause or loop), with its
/// fraction along the trace's arc length.
struct Emphasis { char letter; double t; };

// ----------------------------------------------------------------- lexicon --
struct LearnedWord { int count = 0, sessions = 0, lastSession = -1; double lastUsed = 0; };

class Lexicon {
public:
    std::vector<std::string> words;
    std::vector<double> logPrior, basePrior;
    std::vector<bool> isCore, baseCore;
    std::vector<bool> isMidTier;

    // corpusPath: frequency-ordered word list (one per line).
    // curated: always-core supplement. dictionary: vouches ranks 3000-9000.
    Lexicon(const Config& cfg, const std::string& corpusPath,
            const std::vector<std::string>& curated,
            const std::set<std::string>& dictionary)
        : config(cfg) {
        buckets.resize(26 * 26);
        std::set<std::string> curatedSet(curated.begin(), curated.end());
        double rank = 0;
        std::ifstream f(corpusPath);
        std::string w;
        while (std::getline(f, w)) {
            if (!w.empty() && w.back() == '\r') w.pop_back();   // windows line endings
            if (w.empty() || indexOf.count(w)) continue;
            bool core = rank < 3000 || (rank < 9000 && dictionary.count(w)) || curatedSet.count(w);
            add(w, rank, core, !core && rank < 50000);
            rank += 1;
        }
        // Contractions: subtitle tokenizers split them apart, so none survive
        // corpus cleaning. Glide templates skip their apostrophes.
        static const std::pair<const char*, double> contractions[] = {
            {"i'm",40},{"it's",45},{"don't",55},{"that's",80},{"you're",90},
            {"can't",110},{"i'll",120},{"i've",140},{"he's",150},{"she's",160},
            {"we're",170},{"what's",180},{"didn't",190},{"there's",210},
            {"let's",230},{"i'd",250},{"they're",270},{"doesn't",290},
            {"isn't",320},{"won't",340},{"you'll",360},{"we'll",380},
            {"wasn't",400},{"you've",420},{"he'll",480},{"wouldn't",500},
            {"couldn't",520},{"aren't",560},{"we've",580},{"haven't",600},
            {"shouldn't",650},{"weren't",670},{"hasn't",720},{"they'll",760},
            {"you'd",800},{"they've",840},{"she'll",880},{"hadn't",920},
            {"who's",960},{"ain't",1000},{"here's",1100},{"it'll",1150},
            {"that'll",1200},{"would've",1300},{"could've",1400},{"should've",1500},
        };
        for (auto& [cw, r] : contractions)
            if (!indexOf.count(cw)) add(cw, r, true);
        for (auto& cw : curated)
            if (!indexOf.count(cw)) add(cw, rank++, true);
        for (auto& dw : dictionary)
            if (!indexOf.count(dw)) add(dw, cfg.fallbackRank, false);
    }

    size_t size() const { return words.size(); }
    bool contains(const std::string& w) const { return indexOf.count(lower(w)) != 0; }
    bool isLearned(const std::string& w) const { return learned.count(lower(w)) != 0; }

    std::vector<int> candidateIndices(const std::vector<char>& starts,
                                      const std::vector<char>& ends) const {
        std::vector<int> out;
        for (char s : starts)
            for (char e : ends) {
                if (s < 'a' || s > 'z' || e < 'a' || e > 'z') continue;
                auto& b = buckets[(s - 'a') * 26 + (e - 'a')];
                out.insert(out.end(), b.begin(), b.end());
            }
        return out;
    }

    static int currentSession(double unixTime) { return (int)(unixTime / 86400.0); }

    void reinforce(const std::string& word, int session, double now) {
        std::string w = lower(word);
        if (!indexOf.count(w)) return;
        auto& e = learned[w];
        e.count += 1;
        if (e.lastSession != session) { e.sessions += 1; e.lastSession = session; }
        e.lastUsed = now;
        applyLearnedPrior(w);
    }

    void learn(const std::string& word, int session, double now) {
        std::string w = lower(word);
        if (w.size() < 2 || w.size() > 20 || indexOf.count(w)) return;
        for (char c : w) if (c < 'a' || c > 'z') return;
        add(w, config.fallbackRank, false, false);
        reinforce(w, session, now);
    }

    void forget(const std::string& word) {
        std::string w = lower(word);
        learned.erase(w);
        auto it = indexOf.find(w);
        if (it != indexOf.end()) {
            logPrior[it->second] = basePrior[it->second];
            isCore[it->second] = baseCore[it->second];
        }
    }

    // Recency-decayed most-used, padded from the head of the corpus order.
    std::vector<std::string> topUsed(int n, double now) const {
        std::vector<std::pair<double, std::string>> scored;
        for (auto& [w, e] : learned) {
            double age = std::max(0.0, now - e.lastUsed) / 86400.0;
            scored.push_back({-(e.count * std::pow(0.5, age / 10.0)), w});
        }
        std::sort(scored.begin(), scored.end());
        std::vector<std::string> out;
        std::set<std::string> seen;
        for (auto& [s, w] : scored) {
            if ((int)out.size() >= n) break;
            out.push_back(w); seen.insert(w);
        }
        for (size_t i = 0; i < words.size() && (int)out.size() < n; i++)
            if (!seen.count(words[i])) { out.push_back(words[i]); seen.insert(words[i]); }
        return out;
    }

    std::vector<std::string> complete(const std::string& prefix, int count) const {
        if (prefix.empty()) return {};
        std::vector<std::pair<double, int>> core, fallback;
        for (size_t i = 0; i < words.size(); i++) {
            const auto& w = words[i];
            if (w.size() <= prefix.size() || w.compare(0, prefix.size(), prefix) != 0) continue;
            (isCore[i] ? core : fallback).push_back({-logPrior[i], (int)i});
        }
        std::sort(core.begin(), core.end());
        std::sort(fallback.begin(), fallback.end());
        std::vector<std::string> out;
        for (auto& [p, i] : core) { if ((int)out.size() >= count) break; out.push_back(words[i]); }
        for (auto& [p, i] : fallback) { if ((int)out.size() >= count) break; out.push_back(words[i]); }
        return out;
    }

    // learned-word persistence: "word count sessions lastSession lastUsed" lines
    void loadLearned(const std::string& path) {
        std::ifstream f(path);
        std::string w; LearnedWord e;
        while (f >> w >> e.count >> e.sessions >> e.lastSession >> e.lastUsed) {
            learned[w] = e;
            applyLearnedPrior(w);
        }
    }
    void saveLearned(const std::string& path) const {
        std::ofstream f(path, std::ios::trunc);
        for (auto& [w, e] : learned)
            f << w << ' ' << e.count << ' ' << e.sessions << ' '
              << e.lastSession << ' ' << e.lastUsed << '\n';
    }

private:
    Config config;
    std::unordered_map<std::string, int> indexOf;
    std::vector<std::vector<int>> buckets;
    std::map<std::string, LearnedWord> learned;

    static std::string lower(std::string s) {
        for (auto& c : s) c = (char)std::tolower((unsigned char)c);
        return s;
    }

    void add(const std::string& w, double rank, bool core, bool midTier = false) {
        char f = w.front(), l = w.back();
        if (f < 'a' || f > 'z' || l < 'a' || l > 'z') return;
        int idx = (int)words.size();
        double prior = -std::log(rank + 1.0);
        words.push_back(w);
        logPrior.push_back(prior);
        basePrior.push_back(prior);
        isCore.push_back(core);
        baseCore.push_back(core);
        isMidTier.push_back(midTier);
        buckets[(f - 'a') * 26 + (l - 'a')].push_back(idx);
        indexOf[w] = idx;
    }

    void applyLearnedPrior(const std::string& w) {
        auto it = indexOf.find(w);
        auto le = learned.find(w);
        if (it == indexOf.end() || le == learned.end()) return;
        if (!isCore[it->second]) isMidTier[it->second] = true;   // one use lifts deep tier
        double boost = std::log(1.0 + le->second.count) * 1.2;
        if (le->second.sessions >= 2 && le->second.count >= 3) isCore[it->second] = true;
        logPrior[it->second] = std::min(0.0, basePrior[it->second] + boost);
    }
};

// ----------------------------------------------------------------- decoder --
struct Candidate { std::string word; double score, shape, location; };

class Decoder {
public:
    Decoder(const KeyboardLayout& l, Lexicon& lx, const Config& c)
        : layout(l), lexicon(lx), config(c) {
        shapeNormSize = l.keyPitch * 4.0;
        priorScale = c.priorWeightKeys * l.keyPitch;
        fallbackPenalty = c.fallbackPenaltyKeys * l.keyPitch;
        int n = c.resampleCount;
        posW.resize(n, 1.0);
        if (c.endWeighting)
            for (int i = 0; i < n; i++) {
                double t = (double)i / std::max(n - 1, 1);
                posW[i] = 0.7 + 0.6 * std::pow(std::fabs(2 * t - 1), 1.5);
            }
    }

    std::vector<Candidate> decode(const std::vector<Pt>& rawPath,
                                  const std::vector<Emphasis>& emphases = {}) {
        if (rawPath.size() < 2) return {};
        auto smoothed = smooth(rawPath, config.smoothingPasses);
        auto userLoc = resample(smoothed, config.resampleCount);
        auto userShape = normalizeShape(userLoc, shapeNormSize);
        double userLength = pathLength(smoothed);

        double radius = config.endpointRadiusKeys * layout.keyPitch;
        auto starts = layout.lettersNear(rawPath.front(), radius);
        auto ends = layout.lettersNear(rawPath.back(), radius);
        if (starts.empty()) starts = {layout.nearestLetter(rawPath.front())};
        if (ends.empty()) ends = {layout.nearestLetter(rawPath.back())};

        struct Entry { int idx; double prior, shape, location, score; };
        std::vector<Entry> firstPass;
        for (int idx : lexicon.candidateIndices(starts, ends)) {
            if (!ensureTemplate(idx)) continue;
            double tLen = tmplLen[idx];
            if (userLength > 1e-6) {
                double ratio = tLen / userLength;
                if (ratio < config.lengthRatioMin || ratio > config.lengthRatioMax) continue;
            } else if (tLen > layout.keyPitch) continue;

            double shape = wDist(userShape, tmplShape[idx]);
            double location = wDist(userLoc, tmplLoc[idx]);
            double prior = -lexicon.logPrior[idx] * priorScale;
            if (!lexicon.isCore[idx])
                prior += lexicon.isMidTier[idx]
                       ? config.midFallbackPenaltyKeys * layout.keyPitch
                       : fallbackPenalty;
            // endpoint anchor: elastic matching may not warp away where the
            // trace began and ended
            prior += config.endpointAnchorWeight
                   * (userLoc.front().dist(tmplLoc[idx].front())
                      + userLoc.back().dist(tmplLoc[idx].back()));
            // emphasized letters must appear near their marked positions
            if (!emphases.empty()) {
                for (auto& e : emphases) {
                    bool matched = false;
                    for (auto& [ch, t] : tmplLetters[idx])
                        if (ch == e.letter &&
                            std::fabs(t - e.t) <= config.emphasisPositionTolerance) {
                            matched = true; break;
                        }
                    if (!matched)
                        prior += config.emphasisMissPenaltyKeys * layout.keyPitch;
                }
            }
            firstPass.push_back({idx, prior, shape, location,
                                 shape * config.shapeWeight + location * config.locationWeight + prior});
        }
        std::sort(firstPass.begin(), firstPass.end(),
                  [](const Entry& a, const Entry& b) { return a.score < b.score; });

        int band = std::max(2, (int)(config.resampleCount * config.dtwBandFraction));
        double blend = std::clamp(config.dtwBlend, 0.0, 1.0);
        std::vector<Candidate> results;
        int limit = std::min((int)firstPass.size(), config.rescoreCount);
        for (int i = 0; i < limit; i++) {
            auto& e = firstPass[i];
            double shape = (1 - blend) * e.shape + blend * dtw(userShape, tmplShape[e.idx], band);
            double location = (1 - blend) * e.location + blend * dtw(userLoc, tmplLoc[e.idx], band);
            results.push_back({lexicon.words[e.idx],
                               shape * config.shapeWeight + location * config.locationWeight + e.prior,
                               shape, location});
        }
        std::sort(results.begin(), results.end(),
                  [](const Candidate& a, const Candidate& b) { return a.score < b.score; });

        auto isDeep = [&](const std::string& w) {
            auto it2 = std::find(lexicon.words.begin(), lexicon.words.end(), w);
            if (it2 == lexicon.words.end()) return false;
            size_t idx2 = it2 - lexicon.words.begin();
            return !lexicon.isCore[idx2] && !lexicon.isMidTier[idx2];
        };
        // near-tie protection: rare words only outrank common ones decisively
        if (!results.empty() && isDeep(results[0].word)) {
            double margin = config.deepTierMarginKeys * layout.keyPitch;
            for (size_t k = 1; k < results.size(); k++)
                if (!isDeep(results[k].word)) {
                    if (results[k].score - results[0].score < margin) {
                        auto shallow = results[k];
                        results.erase(results.begin() + k);
                        results.insert(results.begin(), shallow);
                    }
                    break;
                }
        }
        std::vector<Candidate> top(results.begin(),
            results.begin() + std::min((size_t)config.candidateCount, results.size()));
        // reserved rare-word slot
        bool hasDeep = false;
        for (auto& c : top) if (isDeep(c.word)) { hasDeep = true; break; }
        if (!top.empty() && !hasDeep) {
            for (auto& c : results)
                if (isDeep(c.word) &&
                    c.score - top[0].score < config.deepSlotMarginKeys * layout.keyPitch) {
                    if ((int)top.size() == config.candidateCount) top.pop_back();
                    top.push_back(c);
                    break;
                }
        }
        return top;
    }

    char decodeTap(const Pt& p) const { return layout.nearestLetter(p); }

private:
    const KeyboardLayout& layout;
    Lexicon& lexicon;
    Config config;
    double shapeNormSize, priorScale, fallbackPenalty;
    std::vector<double> posW;
    std::unordered_map<int, std::vector<Pt>> tmplLoc, tmplShape;
    std::unordered_map<int, double> tmplLen;
    std::unordered_map<int, std::vector<std::pair<char, double>>> tmplLetters;
    std::vector<double> dtwPrev, dtwCur;

    static std::vector<Pt> smooth(std::vector<Pt> cur, int passes) {
        if (cur.size() <= 4) return cur;
        for (int p = 0; p < passes; p++) {
            auto out = cur;
            for (size_t i = 1; i + 1 < cur.size(); i++)
                out[i] = {(cur[i-1].x + cur[i].x * 2 + cur[i+1].x) / 4,
                          (cur[i-1].y + cur[i].y * 2 + cur[i+1].y) / 4};
            cur = out;
        }
        return cur;
    }

    bool ensureTemplate(int idx) {
        if (tmplLoc.count(idx)) return true;
        std::vector<Pt> poly;
        if (!layout.templateFor(lexicon.words[idx], poly)) return false;
        auto rs = resample(poly, config.resampleCount);
        tmplLoc[idx] = rs;
        tmplShape[idx] = normalizeShape(rs, shapeNormSize);
        double total = pathLength(poly);
        tmplLen[idx] = total;
        // letter arc fractions, repeats collapsed, apostrophes silent
        std::vector<std::pair<char, double>> positions;
        double acc = 0; char last = 0; size_t vertex = 0;
        for (char ch : lexicon.words[idx]) {
            if (!layout.keys.count(ch)) continue;
            if (ch != last) {
                if (vertex > 0) acc += poly[vertex].dist(poly[vertex - 1]);
                positions.push_back({ch, total > 1e-9 ? acc / total : 0});
                vertex++;
            }
            last = ch;
        }
        tmplLetters[idx] = positions;
        return true;
    }

    double wDist(const std::vector<Pt>& a, const std::vector<Pt>& b) const {
        if (a.size() != b.size() || a.empty()) return 1e300;
        double total = 0, wsum = 0;
        for (size_t i = 0; i < a.size(); i++) {
            total += posW[i] * a[i].dist(b[i]);
            wsum += posW[i];
        }
        return total / wsum;
    }

    double dtw(const std::vector<Pt>& a, const std::vector<Pt>& b, int band) {
        int n = (int)a.size(), m = (int)b.size();
        if (!n || !m) return 1e300;
        const double inf = 1e300;
        if ((int)dtwPrev.size() != m + 1) { dtwPrev.assign(m + 1, inf); dtwCur.assign(m + 1, inf); }
        std::fill(dtwPrev.begin(), dtwPrev.end(), inf);
        std::fill(dtwCur.begin(), dtwCur.end(), inf);
        dtwPrev[0] = 0;
        for (int i = 1; i <= n; i++) {
            int lo = std::max(1, i - band), hi = std::min(m, i + band);
            for (int j = std::max(0, lo - 1); j <= std::min(m, hi + 1); j++) dtwCur[j] = inf;
            for (int j = lo; j <= hi; j++) {
                double w = posW[std::min(j - 1, (int)posW.size() - 1)];
                double d = w * a[i - 1].dist(b[j - 1]);
                dtwCur[j] = d + std::min({dtwPrev[j], dtwCur[j - 1], dtwPrev[j - 1]});
            }
            std::swap(dtwPrev, dtwCur);
        }
        return dtwPrev[m] / n;
    }
};

// Turns dwell and winding in a raw trace into letter emphases (see the Swift
// original). Returns the path with loop excursions excised plus deduplicated
// emphases.
inline std::pair<std::vector<Pt>, std::vector<Emphasis>>
detectEmphases(const std::vector<Pt>& path, const std::vector<double>& dwell,
               const KeyboardLayout& layout, const Config& config) {
    if (path.size() < 3 || path.size() != dwell.size()) return {path, {}};
    double pitch = layout.keyPitch;
    double bindRadius = config.emphasisRadiusKeys * pitch;

    std::vector<double> arc{0};
    for (size_t i = 1; i < path.size(); i++) arc.push_back(arc[i-1] + path[i].dist(path[i-1]));
    double totalArc = std::max(arc.back(), 1e-9);

    std::vector<double> turnPrefix{0, 0};
    for (size_t k = 1; k + 1 < path.size(); k++) {
        Pt v1 = path[k] - path[k-1], v2 = path[k+1] - path[k];
        double a = 0;
        if (v1.length() > 1e-9 && v2.length() > 1e-9)
            a = std::atan2(v1.x * v2.y - v1.y * v2.x, v1.x * v2.x + v1.y * v2.y);
        turnPrefix.push_back(turnPrefix.back() + a);
    }

    struct Window { size_t lo, hi; Pt center; double t; };
    std::vector<Window> loops;
    size_t i = 1;
    while (i + 2 < path.size()) {
        size_t j = i + 2;
        bool found = false;
        while (j + 1 < path.size() && arc[j] - arc[i] < pitch * 4.0) {
            double turn = std::fabs(turnPrefix[std::min(j + 1, turnPrefix.size() - 1)] - turnPrefix[i + 1]);
            if (turn >= config.loopMinTurn && path[i].dist(path[j]) < pitch * 0.6) {
                // real loops are round; switchbacks are thin slivers
                // (isoperimetric ratio — see Swift original)
                double area = 0;
                for (size_t k = i; k < j; k++)
                    area += path[k].x * path[k+1].y - path[k+1].x * path[k].y;
                area += path[j].x * path[i].y - path[i].x * path[j].y;
                double perim = (arc[j] - arc[i]) + path[i].dist(path[j]);
                double roundness = 4 * 3.14159265 * std::fabs(area) / 2 /
                                   std::max(perim * perim, 1e-9);
                if (roundness < 0.5) { j++; continue; }
                Pt c;
                for (size_t k = i; k <= j; k++) { c.x += path[k].x; c.y += path[k].y; }
                c.x /= (j - i + 1); c.y /= (j - i + 1);
                loops.push_back({i, j, c, (arc[i] + arc[j]) / 2 / totalArc});
                i = j;
                found = true;
                break;
            }
            j++;
        }
        i += 1;
        (void)found;
    }

    struct Mark { char letter; double t; };
    std::vector<Mark> marks;
    auto bind = [&](const Pt& p) -> char {
        char ch = layout.nearestLetter(p);
        if (ch && layout.keys.at(ch).dist(p) <= bindRadius) return ch;
        return 0;
    };
    for (auto& w : loops)
        if (char ch = bind(w.center)) marks.push_back({ch, w.t});
    for (size_t k = 2; k + 2 < path.size(); k++) {
        double ms = dwell[k] * 1000;
        if (ms >= config.pauseMinMS && ms <= config.pauseMaxMS)
            if (char ch = bind(path[k])) marks.push_back({ch, arc[k] / totalArc});
    }

    std::sort(marks.begin(), marks.end(), [](const Mark& a, const Mark& b) { return a.t < b.t; });
    std::vector<Emphasis> emphases;
    for (auto& m : marks) {
        bool dup = false;
        for (auto& e : emphases)
            if (e.letter == m.letter && std::fabs(e.t - m.t) < config.emphasisPositionTolerance)
                { dup = true; break; }
        if (!dup) emphases.push_back({m.letter, m.t});
    }

    if (loops.empty()) return {path, emphases};
    std::vector<Pt> cleaned;
    size_t k = 0, li = 0;
    while (k < path.size()) {
        if (li < loops.size() && k == loops[li].lo) {
            cleaned.push_back(loops[li].center);
            k = loops[li].hi + 1;
            li++;
        } else cleaned.push_back(path[k++]);
    }
    return {cleaned, emphases};
}

} // namespace tpt
