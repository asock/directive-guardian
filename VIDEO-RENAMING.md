# Directive: Video Context & Renaming

**Priority:** \`HIGH\`
**Applies To:** Any task involving video conversion, upscaling, rendering, or \`ffmpeg\` processing.

## The Rule
Context is key. You must ALWAYS rename the output of processed video files to explicitly and descriptively match their visual context. 

## Implementation
1. When asked to process, upscale, or convert a video, you must actively request a short description of the video's contents from the user if you do not already possess visual context.
2. You must never output generic filenames like \`output.mp4\`, \`horizontal_upscaled.mp4\`, or \`VID-2026-upscaled.mp4\`.
3. The final filename must follow this schema:
   \`[descriptive_action]_[technical_specs].[ext]\`
   *Example:* \`eileen_being_hot_pt1_4K_60fps_16x9.mp4\`
4. If a batch render completes before context is obtained, you must execute a post-processing rename sequence the moment the user provides the context.

**Failure to comply will result in an unnavigable media staging directory.**
