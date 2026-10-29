<script lang="ts">
    let { key }: { key: string } = $props();
</script>

<span class="keycap">{key}</span>

<style>
    .keycap {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-width: 22px;
        min-height: 20px;
        padding: 0 6px;
        border-radius: 5px;
        background: var(--fill-3);
        font-size: 11px;
        font-weight: 600;
        white-space: nowrap;
    }
</style>
