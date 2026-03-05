# TAK Server Plugins

This directory contains TAK Server plugin source code that is compiled during Docker image builds.

## tak-gpt Plugin

AI-powered chat assistant for TAK Server.

### Initial Setup

Clone the tak-gpt repository into this directory:

```bash
cd plugins
git clone https://github.com/raytheonbbn/tak-gpt.git
```

### Directory Structure

```
plugins/
└── tak-gpt/
    ├── lib/
    │   └── src/
    │       └── main/
    │           └── java/
    │               └── tak/
    │                   └── server/
    │                       └── plugins/
    ├── README.md
    └── ...
```

### Making Changes

1. Modify source code in `tak-gpt/`
2. Rebuild Docker image: `npm run deploy:dev`
3. Plugin is automatically compiled and included

### Customizations

The following customizations are automatically applied during build:
- Team color: Changed from Cyan to Purple
- Role: Changed from "Team Member" to "HQ"

These are applied via `sed` commands in the Dockerfile. To make permanent changes, edit the source files directly.

### Build Configuration

The plugin is built using:
- `docker/tak-server/plugin-build.gradle` - Gradle configuration
- `docker/tak-server/extract-tak-deps.sh` - TAK dependency extraction

### Notes

- The `tak-gpt/` directory should be tracked in your repository
- Make changes directly to the source code as needed
- Plugin is compiled fresh on each Docker build
