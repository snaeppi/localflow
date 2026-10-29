<script lang="ts">
    let { title, first = false }: { title: string; first?: boolean } = $props();
</script>

<div class="title" class:first>{title}</div>

<style>
    .title {
        font-weight: 600;
        padding-top: 14px;
    }

    /* At the top of a page, level with where a card would start. */
    .first {
        padding-top: 0;
    }
</style>
