# Saturates the GPU with fp16 matmuls (like a training run) until killed.
import mlx.core as mx
a = mx.random.normal((4096, 4096)).astype(mx.float16)
b = mx.random.normal((4096, 4096)).astype(mx.float16)
while True:
    for _ in range(20):
        a = (a @ b) * 0.0001
    mx.eval(a)
