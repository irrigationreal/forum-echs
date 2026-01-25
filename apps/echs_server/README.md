# EchsServer

HTTP daemon for ECHS.

This app exposes a wire API for:

- Creating thread sessions
- Updating thread configuration (model, reasoning, instructions, tools, cwd)
- Sending messages (queue/steer)
- Streaming events over SSE

See the umbrella `README.md` for API examples.

