import { defineConfig } from "vite";

export default defineConfig({
  // allow importing the forge artifacts from ../contracts/out
  server: { fs: { allow: [".."] } },
});
