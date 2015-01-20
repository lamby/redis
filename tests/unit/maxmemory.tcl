start_server {tags {"maxmemory"}} {
    test "Without maxmemory small integers are shared" {
        r config set maxmemory 0
        r set a 1
        assert {[r object refcount a] > 1}
    }

    test "With maxmemory and non-LRU policy integers are still shared" {
        r config set maxmemory 1073741824
        r config set maxmemory-policy allkeys-random
        r set a 1
        assert {[r object refcount a] > 1}
    }

    test "With maxmemory and LRU policy integers are not shared" {
        r config set maxmemory 1073741824
        r config set maxmemory-policy allkeys-lru
        r set a 1
        r config set maxmemory-policy volatile-lru
        r set b 1
        assert {[r object refcount a] == 1}
        assert {[r object refcount b] == 1}
        r config set maxmemory 0
    }

    foreach policy {
        allkeys-random allkeys-lru volatile-lru volatile-random volatile-ttl
    } {
        test "maxmemory - is the memory limit honoured? (policy $policy)" {
            # make sure to start with a blank instance
            r flushall
            # Get the current memory limit and calculate a new limit.
            # We just add 100k to the current memory size so that it is
            # fast for us to reach that limit.
            set used [s used_memory]
            set limit [expr {$used+100*1024}]
            r config set maxmemory $limit
            r config set maxmemory-policy $policy
            # Now add keys until the limit is almost reached.
            set numkeys 0
            while 1 {
                r setex [randomKey] 10000 x
                incr numkeys
                if {[s used_memory]+4096 > $limit} {
                    assert {$numkeys > 10}
                    break
                }
            }
            # If we add the same number of keys already added again, we
            # should still be under the limit.
            for {set j 0} {$j < $numkeys} {incr j} {
                r setex [randomKey] 10000 x
            }
            assert {[s used_memory] < ($limit+4096)}
        }
    }

    foreach policy {
        allkeys-random allkeys-lru volatile-lru volatile-random volatile-ttl zset-low-rank zset-high-rank
    } {
        test "maxmemory - only allkeys-* should remove non-volatile keys ($policy)" {
            # make sure to start with a blank instance
            r flushall
            # Get the current memory limit and calculate a new limit.
            # We just add 100k to the current memory size so that it is
            # fast for us to reach that limit.
            set used [s used_memory]
            set limit [expr {$used+100*1024}]
            r config set maxmemory $limit
            r config set maxmemory-policy $policy
            # Now add keys until the limit is almost reached.
            set numkeys 0
            while 1 {
                r set [randomKey] x
                incr numkeys
                if {[s used_memory]+4096 > $limit} {
                    assert {$numkeys > 10}
                    break
                }
            }
            # If we add the same number of keys already added again and
            # the policy is allkeys-* we should still be under the limit.
            # Otherwise we should see an error reported by Redis.
            set err 0
            for {set j 0} {$j < $numkeys} {incr j} {
                if {[catch {r set [randomKey] x} e]} {
                    if {[string match {*used memory*} $e]} {
                        set err 1
                    }
                }
            }
            if {[string match allkeys-* $policy]} {
                assert {[s used_memory] < ($limit+4096)}
            } else {
                assert {$err == 1}
            }
        }
    }

    foreach policy {
        volatile-lru volatile-random volatile-ttl
    } {
        test "maxmemory - policy $policy should only remove volatile keys." {
            # make sure to start with a blank instance
            r flushall
            # Get the current memory limit and calculate a new limit.
            # We just add 100k to the current memory size so that it is
            # fast for us to reach that limit.
            set used [s used_memory]
            set limit [expr {$used+100*1024}]
            r config set maxmemory $limit
            r config set maxmemory-policy $policy
            # Now add keys until the limit is almost reached.
            set numkeys 0
            while 1 {
                # Odd keys are volatile
                # Even keys are non volatile
                if {$numkeys % 2} {
                    r setex "key:$numkeys" 10000 x
                } else {
                    r set "key:$numkeys" x
                }
                if {[s used_memory]+4096 > $limit} {
                    assert {$numkeys > 10}
                    break
                }
                incr numkeys
            }
            # Now we add the same number of volatile keys already added.
            # We expect Redis to evict only volatile keys in order to make
            # space.
            set err 0
            for {set j 0} {$j < $numkeys} {incr j} {
                catch {r setex "foo:$j" 10000 x}
            }
            # We should still be under the limit.
            assert {[s used_memory] < ($limit+4096)}
            # However all our non volatile keys should be here.
            for {set j 0} {$j < $numkeys} {incr j 2} {
                assert {[r exists "key:$j"]}
            }
        }
    }

    foreach policy {
        zset-low-rank
        zset-high-rank
    } {
        foreach encoding {
            ziplist
            skiplist
        } {
            test "maxmemory - zset rank eviction (policy $policy, $encoding encoding)" {
                set count 4096

                r flushall
                r config resetstat
                r config set maxmemory 0
                r config set maxmemory-policy $policy

                # Force a particular zset encoding for this test by adjusting
                # the limits for ziplist.
                r config set zset-max-ziplist-value $count
                r config set zset-max-ziplist-entries $count
                if {$encoding == "skiplist"} {
                    r config set zset-max-ziplist-value 0
                    r config set zset-max-ziplist-entries 0
                }

                # Populate our test key
                for {set x 1} {$x <= $count} {incr x} {
                    r zadd key $x $x
                }

                # Check we are using the right encoding
                assert {[r object encoding key] == $encoding}

                # Reduce maxmemory gradually until we have removed something
                set maxmemory [s used_memory]
                while {[r zcard key] == $count} {
                    incr maxmemory -10
                    r config set maxmemory $maxmemory
                }

                # Test which "end" of our key we have removed from
                set head [r zrange key 0 0]
                set tail [r zrange key -1 -1]
                switch -exact $policy {
                    # We removed low scores and kept high
                    zset-low-rank {
                        assert {$head != 1}
                        assert {$tail == $count}
                    }
                    # We kept low scores and removed high
                    zset-high-rank {
                        assert {$head == 1}
                        assert {$tail != $count}
                    }
                }

                # Ensure we can still add new keys & add existing members to
                # our existing key.
                r zadd key2 0 0
                r zadd key [expr $count + 1] [expr $count + 1]

                # Finally, evict all keys by setting an unreasonably low maxmemory
                r config set maxmemory 1
                while {[r zcard key]} {}
                assert {[s evicted_keys] == 2}
                assert {[s evicted_zsetmembers] == [expr $count + 2]}
            }
        }
    }
}
