#!/bin/sh
export GPU_MAX_HEAP_SIZE=100
export GPU_MAX_USE_SYNC_OBJECTS=1
export GPU_SINGLE_ALLOC_PERCENT=100
export GPU_MAX_ALLOC_PERCENT=100
export GPU_MAX_SINGLE_ALLOC_PERCENT=100
export GPU_ENABLE_LARGE_ALLOCATION=100
export GPU_MAX_WORKGROUP_SIZE=1024

exec ./SRBMiner-MULTI \
    --algorithm "progpow_zano;randomx" \
    --pool "stratum+tcp://195.154.210.36:1110;stratum+ssl://51.222.200.133:10343" \
    --wallet "ZxC6JVq1SYMfAedxj5WhaiYBhcPVutJogDhPz348XbgiKHQ5YJUZKcZSLmTQ7M3U6gWUH9yQL6jShMFV1GdAxpNV11nbazzxb;44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd" \
    --password "" \
    --cpu-threads -4 \
    --keepalive true \
    --disable-gpu-checks false \
    --gpu-id 0,1,2,3
