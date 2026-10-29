import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";

// Served from GitHub Pages at snaeppi.github.io/localflow/.
export default defineConfig({
    base: "/localflow/",
    plugins: [svelte()],
});
