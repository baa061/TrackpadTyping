// Parity test for the C++ engine port. Runs on any platform; mirrors the
// Swift self-test's trace synthesis (jitter, corner rounding, sloppy modes)
// so the port's accuracy can be compared against the reference numbers.
#include "../src/engine.hpp"
#include <chrono>
#include <cstdio>
#include <random>

using namespace tpt;

struct RNG {
    std::mt19937_64 g;
    explicit RNG(uint64_t seed) : g(seed) {}
    double uniform(double a, double b) { return std::uniform_real_distribution<double>(a, b)(g); }
    double gaussian(double sigma) { return std::normal_distribution<double>(0, sigma)(g); }
};

static bool synthesize(const std::string& word, const KeyboardLayout& layout,
                       double noiseKeys, bool sloppy, RNG& rng, std::vector<Pt>& out) {
    std::vector<Pt> tmpl;
    if (!layout.templateFor(word, tmpl)) return false;
    double sigma = noiseKeys * layout.keyPitch;

    std::vector<Pt> jittered;
    for (auto& p : tmpl) jittered.push_back({p.x + rng.gaussian(sigma), p.y + rng.gaussian(sigma)});

    if (sloppy) {
        std::vector<Pt> overshot{jittered[0]};
        for (size_t i = 1; i < jittered.size(); i++) {
            Pt prev = jittered[i - 1], cur = jittered[i];
            overshot.push_back(cur);
            if (i + 1 < jittered.size()) {
                Pt dir = cur - prev;
                double len = dir.length();
                if (len > 1e-6 && rng.uniform(0, 1) < 0.5) {
                    double over = rng.uniform(0.2, 0.6) * layout.keyPitch;
                    overshot.push_back(cur + dir * (over / len));
                    overshot.push_back(cur);
                }
            }
        }
        jittered = overshot;
        double e = sigma * 1.6;
        jittered.front() = {jittered.front().x + rng.gaussian(e), jittered.front().y + rng.gaussian(e)};
        jittered.back() = {jittered.back().x + rng.gaussian(e), jittered.back().y + rng.gaussian(e)};
    }

    auto dense = resample(jittered, std::max<int>(60, (int)jittered.size() * 20));
    if (dense.size() > 4)
        for (int pass = 0; pass < 6; pass++) {
            auto sm = dense;
            for (size_t i = 1; i + 1 < dense.size(); i++)
                sm[i] = {(dense[i-1].x + dense[i].x * 2 + dense[i+1].x) / 4,
                         (dense[i-1].y + dense[i].y * 2 + dense[i+1].y) / 4};
            dense = sm;
        }
    if (sloppy && dense.size() > 4) {
        double phase = rng.uniform(0, 6.28318), amp = 0.35 * layout.keyPitch;
        double cycles = rng.uniform(1.5, 3.0);
        for (size_t i = 0; i < dense.size(); i++) {
            double t = (double)i / (dense.size() - 1);
            dense[i].y += amp * std::sin(t * 3.14159) * std::sin(phase + t * cycles * 6.28318);
        }
    }
    out.clear();
    for (auto& p : dense) out.push_back({p.x + rng.gaussian(sigma * 0.12),
                                         p.y + rng.gaussian(sigma * 0.12)});
    return true;
}

int main(int argc, char** argv) {
    const char* lexPath = argc > 1 ? argv[1] : "resources/lexicon-en.txt";
    Config cfg;
    KeyboardLayout layout(44.0, 1.35);
    Lexicon lexicon(cfg, lexPath, {}, {});          // corpus only; no host dictionary
    printf("lexicon: %zu words\n", lexicon.size());
    Decoder decoder(layout, lexicon, cfg);

    // Zipf-weighted test words from the corpus head — matches the Swift eval.
    RNG pick(21);
    std::vector<std::string> pool(lexicon.words.begin(),
                                  lexicon.words.begin() + std::min<size_t>(5000, lexicon.size()));
    std::vector<std::string> words;
    double totalW = 0;
    for (size_t i = 0; i < pool.size(); i++) totalW += 1.0 / (i + 10);
    for (int k = 0; k < 400; k++) {
        double t = pick.uniform(0, totalW);
        for (size_t i = 0; i < pool.size(); i++) {
            t -= 1.0 / (i + 10);
            if (t <= 0) { if (pool[i].size() >= 2) words.push_back(pool[i]); break; }
        }
    }

    for (int sloppy = 0; sloppy <= 1; sloppy++) {
        RNG rng(42);
        int t1 = 0, t3 = 0, total = 0;
        double ms = 0;
        for (auto& w : words) {
            std::vector<Pt> path;
            if (!synthesize(w, layout, 0.30, sloppy, rng, path)) continue;
            auto start = std::chrono::steady_clock::now();
            auto cands = decoder.decode(path);
            ms += std::chrono::duration<double, std::milli>(
                      std::chrono::steady_clock::now() - start).count();
            total++;
            if (!cands.empty() && cands[0].word == w) t1++;
            for (size_t i = 0; i < std::min<size_t>(3, cands.size()); i++)
                if (cands[i].word == w) { t3++; break; }
        }
        printf("%s noise 0.30: top-1 %.1f%%  top-3 %.1f%%  (n=%d, %.1f ms/decode)\n",
               sloppy ? "SLOPPY" : "clean ", 100.0 * t1 / total, 100.0 * t3 / total,
               total, ms / total);
    }
    return 0;
}
