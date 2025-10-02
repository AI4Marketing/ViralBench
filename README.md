# ViralBench

**ViralBench** is a multimodal benchmark for evaluating whether AI models truly *understand* social-video virality. It measures not only raw engagement prediction, but also the model’s ability to explain *why* a post may (or may not) perform—covering visual style, storytelling, audience inference, brand-safety risks and other factors.

---

## Why ViralBench?

There are currently no benchmarks focused on evaluating AI models—especially multimodal language models—for their ability to understand social media virality. Our goal is to develop MLLM-based agentic AI systems that can reason about, but are not limited to, the following aspects:

* Video content and captions
* Account metadata and posting history
* Music track identity and popularity
* Current trends
* Hashtags
* Platform-specific norms (e.g., TikTok, Instagram Reels, YouTube Shorts)

---

## Spec

**Inputs you want fused:**
- Video + post script/caption
- Account metadata
- Music track (and its popularity)
- Current trending topics
- Hashtags
- Platform (TikTok/IG/YouTube, etc.)

**Outputs/explanations you want:**
- Predict engagements/likes (a numeric score with confidence)
- Describe visual styles & production (e.g., cuts, camera, color, VFX)
- Describe storytelling techniques (hooks, pacing, CTA)
- Infer target audiences (demographics/interests/communities)
- Flag red flags (copyright, policy/brand-safety issues, spammy hashtags)

---

## License

Code under **Apache-2.0**. 
