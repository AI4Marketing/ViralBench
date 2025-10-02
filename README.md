# ViralBench

**ViralBench** is a multimodal benchmark for evaluating whether AI models truly *understand* social-video virality. It measures not only raw engagement prediction, but also the model’s ability to explain *why* a post may (or may not) perform—covering visual style, storytelling, audience inference, and brand-safety risks.

---

## Why ViralBench?

Most “virality models” stop at a single number (likes/engagement). Real-world social performance depends on **fusing**:

* Video content + caption
* Account metadata & history
* Music track identity & popularity
* Current trends
* Hashtags
* Platform norms (TikTok / IG Reels / YouTube Shorts)

ViralBench evaluates this full-stack understanding with **numeric predictions**, **structured explanations**, and **safety flags**, across platforms and time.

---

## Tasks & Expected Outputs

For each post, models receive a fused input (see schema) and must output:

1. **Engagement / Likes Prediction**

   * `score`: numeric virality score (continuous; see target definition)
   * `confidence`: 0–1 confidence for calibration evaluation

2. **Visual Style & Production Description**

   * E.g., *cuts per minute, camera motion, color palette, VFX use, text overlays, meme format, b-roll, transitions*

3. **Storytelling Techniques**

   * E.g., *hook strength, pacing arc, structure (setup → build → payoff), CTA quality/type*

4. **Target Audience Inference**

   * Demographics (binned), interests, sub-communities (e.g., “gym-tok,” “beauty-review,” “AI-builder”)

5. **Red-Flag Detection**

   * Copyright, brand-safety/policy risks, spammy/ban-shadowed hashtags, medical/financial claims, sensitive topics

---

## Input Schema (per post)

```json
{
  "id": "post_000123",
  "platform": "tiktok | instagram | youtube",
  "timestamp": "2025-08-13T17:32:00Z",
  "video": {
    "uri": "s3://.../post_000123.mp4",
    "duration_sec": 27.6,
    "frame_rate": 30
  },
  "caption": "POV: you finally hit depth 🏋️‍♂️ #legday #squat",
  "account": {
    "account_id": "acct_987",
    "category": "fitness_creator",
    "followers": 183450,
    "avg_views_30d": 92500,
    "region": "US",
    "post_freq_30d": 18
  },
  "music": {
    "track_id": "t_4412",
    "name": "Hype Loop",
    "is_original": false,
    "popularity_score": 0.78
  },
  "trending_topics": [
    {"topic": "back-to-school", "popularity": 0.65}
  ],
  "hashtags": ["#legday", "#squat"],
  "fold": "train | dev | test"
}
```

---

## Output Schema (per post)

```json
{
  "id": "post_000123",
  "pred": {
    "engagement_score": 0.43,
    "confidence": 0.78
  },
  "visual_style": {
    "tags": ["fast-cuts", "handheld", "high-contrast", "text-overlay"],
    "estimates": {
      "cuts_per_min": 48,
      "camera_motion": "handheld",
      "color_palette": "high-contrast",
      "vfx_elements": ["speed-ramp"]
    }
  },
  "storytelling": {
    "hook": "countdown cold-open",
    "pacing": "fast",
    "structure": ["setup", "payoff"],
    "cta": "follow-for-program"
  },
  "target_audience": {
    "demographics": {
      "age_bins": {"13-17": 0.05, "18-24": 0.45, "25-34": 0.35, "35+": 0.15},
      "regions": {"US": 0.6, "EU": 0.25, "Other": 0.15}
    },
    "interests": ["weightlifting", "home-gym", "sports-science"],
    "communities": ["gym-tok", "strength-coach"]
  },
  "red_flags": [
    {"type": "spammy_hashtags", "item": "#follow4follow", "severity": "low"},
    {"type": "copyright_music", "item": "Hype Loop", "severity": "medium"}
  ],
  "explanation": "Hook lands in first 1s with countdown + payoff PR. Fast cuts and speed ramps match track energy. Trend alignment is moderate; niche is clear (strength PRs)."
}
```

---

## Target Definition (What are we predicting?)

We evaluate prediction on a **normalized engagement target** that is robust across accounts and platforms:

* **Engagement Rate (ER)** = `(likes + comments + shares) / views`
* We compute `y = zscore( log1p(ER) )` within platform + week buckets to control for time/platform drift.
* Your `engagement_score` should approximate `y` (continuous).

---

## Metrics

**Prediction Quality**

* **Spearman ρ** (rank correlation)
* **MAE / RMSE** on `y`
* **Top-k AUC** (detecting top decile posts)
* **Calibration**: ECE on `confidence` buckets

**Explanations & Structure**

* **Visual Style**: F1 (micro/macro) against expert tags; numeric estimate error (e.g., cuts/min MAE)
* **Storytelling**: F1 on annotated facets (hook, pacing, structure, CTA)
* **Audience Inference**: JSD between predicted and ground-truth audience distributions (where available) + Top-1/Top-3 community accuracy
* **Red Flags**: multilabel Precision/Recall/F1; severity-weighted score

**Composite Score**

* `Overall = 0.45*Prediction + 0.20*Calibration + 0.20*Explainability + 0.15*Safety`

  * *Explainability* aggregates style/storytelling/audience
  * *Safety* comes from red-flag detection

---

## Data Splits & Generalization

* **Train / Dev / Test** with **time-based** and **account-disjoint** splits to prevent leakage.
* **Challenge sets** for:

  * Trend-driven music vs. original audio
  * Low-follower but high-engagement creators (“underdogs”)
  * Cross-platform transfer (train TikTok → test Reels/Shorts)
  * Cold-start accounts
  * Long/short duration extremes

---

## Quickstart

```bash
# 1) Install
pip install -e .

# 2) Data layout
data/
  videos/...
  metadata.jsonl
  splits/{train.jsonl,dev.jsonl,test.jsonl}
  annotations/{style.jsonl,story.jsonl,audience.jsonl,safety.jsonl}
  labels/test_targets.jsonl  # hidden for official eval

# 3) Run baseline
viralbench baseline --config configs/baseline.yaml --out runs/baseline/

# 4) Evaluate your predictions
viralbench eval \
  --pred runs/your_model/preds_test.jsonl \
  --refs data/labels/test_targets_proxy.jsonl \
  --out runs/your_model/metrics.json
```

---

## Baselines

* **Heuristic-GBM**: tabular features (account priors, music popularity, hashtag stats, posting hour, duration).
* **Vision-Text LLM**: video frames + caption → regression head + structured tag extraction.
* **Late-Fusion**: (Vision/Text) + (Tabular priors) with calibration layer.

All baselines output the full schema (scores, explanations, flags).

---

## Evaluation Protocol

* **Official leaderboard** uses a hidden test set.
* Submissions are a single JSONL with the output schema above (one line per `id`).
* **Length limits**: `explanation` ≤ 500 chars; each list ≤ 16 items.
* **Determinism**: set seeds; no external data unless declared (report sheet provided).

---

## Red-Flag Taxonomy (starter)

* **Copyright**: unlicensed music, third-party footage/logos
* **Policy / Brand Safety**: hate, harassment, adult/sexual, minors, dangerous acts, medical/financial claims
* **Spammy Patterns**: engagement-bait, banned/flagged hashtags, excessive tags
* **Misinformation**: health/finance/geo-political (where labeled)

Each item includes `type`, optional `item`, and `severity ∈ {low, medium, high}`.

---

## Ethics, Privacy, and Responsible Use

* We respect platform ToS; dataset construction prioritizes public posts, creator consent (where applicable), and aggregation of **non-PII** fields.
* We provide a **Data Card** describing sources, sampling, biases, and annotation quality.
* Red-flag outputs are **advisory**, not moderation verdicts.
* Please avoid deploying raw benchmark scores as automated moderation or creator scoring without human review.

---

## Roadmap

* 🔜 Multi-language captions & cross-locale generalization
* 🔜 Temporal features (series of posts, decay, comeback effects)
* 🔜 Creator intent & CTA quality scoring
* 🔜 More robust audience ground truth via opt-in insights
* 🔜 Open inference API + agent-loop integration (e.g., SocialManager)

---

## Contributing

PRs welcome! Useful contributions include:

* New challenge sets and platform adapters
* Annotation guidelines/rubrics improvements
* Better baselines and calibration layers
* Audits for bias/fairness and attack surfaces

See `CONTRIBUTING.md` for style, testing, and dataset ethics checklists.

---

## Citation

If you use ViralBench in research, please cite:

```bibtex
@inproceedings{viralbench2025,
  title={ViralBench: Evaluating Multimodal Virality Understanding in Social Video},
  author={Your Name and Collaborators},
  booktitle={Proceedings of the ____},
  year={2025}
}
```

---

## License

Code under **Apache-2.0**. Dataset licensing varies by subset—see `DATA_LICENSES.md`.

---

## FAQ (short)

* **What exactly is the target?**
  Z-scored `log1p(Engagement Rate)` within platform×week buckets.

* **Do I need the raw video?**
  Yes for full tasks; we also provide vision features for speed.

* **Can I use external data?**
  Allowed in an “open” track with disclosure; “closed” track forbids it.

* **How are free-text explanations scored?**
  Primarily against expert tags (F1/MAE). We also provide an optional rubric-guided judge for qualitative tie-breaks.

---

**Ready to build models that *explain* virality, not just guess it?**
Welcome to **ViralBench**.
