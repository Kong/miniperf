# miniperf

A minimalistic performance testing script, designed for local execution.

## Usage

```
miniperf.sh <mode> [noise]
```

where `mode` is one of:

* `baseline` - each service has `key-auth`, each consumer has a key
* `baseline_no_plugins` - no plugins
* `multi_plugins` - each service has `key-auth`, `correlation-id`, `udp-log`
* `extra_plugins` - each service has `key-auth`, another service not used
  in the test has 5 other plugins configured.

All modes create 10 routes, 10 services, 100 consumers.

If you add `noise` as a second argument, the script will continuously add
routes and plugins in the background as the test runs. This is useful for
testing the impact of router and plugin iterator reconfiguration.

Test output is appended to a file called `miniperf.$MODE.wrk.log`.

**Note** Running the test will reset your Kong database and re-run migrations.
This is designed for running in a developer environment.

## Caveats

As you will quickly see from test results, running this on your local
development machine produces a large variability in test results. Running it
on a dedicated bare-metal box produces less variation, but it still happens.
Keep that in mind when looking at results. This script is more useful to catch
substantial regressions, such as over 10% variation.
