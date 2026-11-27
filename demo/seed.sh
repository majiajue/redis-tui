#!/bin/sh
set -eu

redis() { redis-cli -e -h redis "$@" >/dev/null; }

redis SET demo:order:1001 '{"id":1001,"status":"ready","items":[{"sku":"tea","quantity":2}]}'
redis SET demo:order:1002 '{"id":1002,"status":"pending","items":[{"sku":"coffee","quantity":1}]}'
redis HSET demo:customer:42 name Lin city Shanghai status active
redis SADD demo:tags hot new seasonal
redis ZADD demo:scores 120 Lin 90 Chen 75 Wang
redis DEL demo:queue demo:events
redis RPUSH demo:queue pack ship deliver
redis XADD demo:events '*' event packed order 1001
redis XADD demo:events '*' event shipped order 1001
head -c 98304 /dev/zero | tr '\000' 'x' | redis -x SET demo:large:payload
redis -n 1 SET demo:order:1001 '{"id":1001,"status":"archived","source":"DB 1"}'
redis -n 1 SET demo:archive:note 'This key exists only in DB 1.'
printf 'Loaded demo keys in DB 0 and DB 1.\n'
