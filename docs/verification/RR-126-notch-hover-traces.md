# RR-126 notch hover trace stability

Manual check for a Mac display with a camera notch:

1. Start a Relay Runner voice session from a git repo with orchestration traces enabled.
2. Dispatch or run work that streams working trace text into the notch.
3. While trace text is active, hover the notch glyph and keep the pointer still over the glyph.
4. The notch should expand once, hold the expanded trace presentation, and let trace text update or scroll without repeated expand/collapse animation.
5. Move the pointer away from the glyph. The notch should collapse only after hover ends or the working activity exits.

Automated coverage: `NotchStatusPlacementTests.testWorkingProgressStreamUpdatesDoNotRestartHoverDwell` verifies that streamed trace updates keep the hover dwell active and do not request a new content-driven placement animation while the working trace is hovered.
