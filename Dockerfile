# Runs the MCP server for introspection/listing purposes (Smithery, Glama, etc).
#
# Note: this is a *local* stdio MCP server designed to run alongside a Godot
# editor on the same machine (see smithery.yaml). Inside this container there
# is no Godot editor to talk to, so the server starts and answers MCP
# introspection requests (initialize / tools-list) fine, but tools that call
# into the Godot bridge will fail until GODOT_PROJECT_PATH/GODOT_BIN point at
# a real project and editor.
FROM node:20-alpine

WORKDIR /app/server

COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev

COPY server/server.mjs ./

ENTRYPOINT ["node", "server.mjs"]
