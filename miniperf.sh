#!/usr/bin/env bash

export PATH=./bin:/usr/local/openresty/bin:$PATH

KONG=localhost
KONG_PROXY=http://${KONG}:8000
KONG_ADMIN=http://${KONG}:8001
KONG_DEMO_UPSTREAM_PORT=12345
KONG_DEMO_UPSTREAM_URL=http://127.0.0.1:${KONG_DEMO_UPSTREAM_PORT}

curl_output=/dev/null

n_services=10
n_routes=10
n_consumers=100
plugins=()
extra_services=0
extra_plugins=()

wrk_count=5
wrk_conns=100
wrk_threads=20
wrk_duration=10

################################################################################

[ "$1" = "clean" ] && {
   rm miniperf.wrk.lua
   rm -rf miniperf.nginx.prefix
   rm miniperf.*.wrk.log
   exit 0
}

function die() {
   echo -e "\033[1;31m *** $@\033[0m"
   echo
   exit 1
}

################################################################################

kong version &> /dev/null || die "kong is not in PATH."
openresty -V &> /dev/null || die "openresty is not in PATH."
curl --version &> /dev/null || die "curl is not in PATH."
wrk --version | grep -q wrk &> /dev/null || die "wrk is not in PATH."

[ "$1" ] || {
   echo "Usage: $0 <mode> [noise]"
   echo "where mode is one of:"
   echo "   baseline"
   echo "   baseline_no_plugins"
   echo "   multi_plugins"
   echo "   extra_plugins"
   echo
   echo "If you add \"noise\" as a second argument, the script will"
   echo "continuously add routes and plugins in the background as the"
   echo "test runs."
   echo
   exit 1
}

################################################################################

OS=$(uname -s)

[ "$OS" = "Linux" ] && {
   [ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ] && {
      old_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
      for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
      do
         echo "performance" | sudo tee $gov &> /dev/null
      done
   }
}

################################################################################

scenario=$1
again=

if [ "$scenario" = "again" ]
then
   scenario=$(cat .miniperf.again)
   again=1
fi

cat <<EOF > miniperf.kong.conf
prefix = miniperf.kong.prefix
database = postgres
pg_password = kong
EOF

if ! [ "$again" ]
then
   kong stop -p miniperf.kong.prefix
   rm -rf miniperf.kong.prefix
   pkill nginx
   kong migrations reset --yes -c miniperf.kong.conf
   kong migrations bootstrap -c miniperf.kong.conf
   kong start -c miniperf.kong.conf
fi

curl "$KONG_ADMIN"/ &> /dev/null || die "Kong is not running."

################################################################################

case "$scenario" in
--all-to)
   shift
   mkdir -p $1
   for s in baseline baseline_no_plugins multi_plugins extra_plugins
   do
      $0 $s
      mv *.wrk.log $1
   done
   exit 0
   ;;
baseline)
   plugins=("key-auth")
   ;;
baseline_no_plugins)
   ;;
multi_plugins)
   plugins=("key-auth" "correlation-id" "udp-log")
   ;;
extra_plugins)
   plugins=("key-auth")
   extra_services=1
   extra_plugins=("basic-auth" "correlation-id" "udp-log" "cors" "bot-detection")
   ;;
*)
   die "Unknown configuration '$1'"
   ;;
esac

shift

################################################################################

function add_plugin() {
   local service_name=$1
   case "$plugin" in
   udp-log)
      curl $KONG_ADMIN/services/$service_name/plugins -d "name=$plugin" -d "config.host=127.0.0.1" -d "config.port=10001" &> $curl_output
      ;;
   *)
      curl $KONG_ADMIN/services/$service_name/plugins -d "name=$plugin" &> $curl_output
      ;;
   esac
}

if ! [ "$again" ]
then

   echo "Creating $n_services services, each with $n_routes routes..."
   for (( i = 1; i <= n_services; i++ ))
   do
      service_name="service-$i"
      curl $KONG_ADMIN/services -d "name=$service_name" -d "url=$KONG_DEMO_UPSTREAM_URL" &> $curl_output
      for plugin in "${auto_plugins[@]}"
      do
         add_plugin "$service_name"
      done
      for (( j = 1; j <= n_routes; j++ ))
      do
         route_name=s$i-r$j
         curl $KONG_ADMIN/services/$service_name/routes -d "name=$route_name" -d "paths[]=/$route_name" &> $curl_output
      done
   done

   echo "Creating $extra_services extra services..."
   for (( i = 1; i <= extra_services; i++ ))
   do
      service_name="extra-$i"
      curl $KONG_ADMIN/services -d "name=$service_name" -d "url=$KONG_DEMO_UPSTREAM_URL" &> $curl_output
      for plugin in "${extra_plugins[@]}"
      do
         add_plugin "$service_name"
      done
   done

   echo "Creating $n_consumers consumers..."
   for (( i = 1; i <= n_consumers; i++ ))
   do
      consumer_name="consumer-$i"
      curl $KONG_ADMIN/consumers -d "username=$consumer_name" &> $curl_output
      curl $KONG_ADMIN/consumers/$consumer_name/key-auth -d "key=$consumer_name" &> $curl_output
   done
fi

################################################################################

cat <<EOF > miniperf.wrk.lua
--This script is executed in conjuction with the wrk benchmarking tool via demo.sh
math.randomseed(os.time()) -- Generate PRNG seed
local rand = math.random -- Cache random method

-- Get env vars for consumer and api count or assign defaults
local consumer_count = $n_consumers
local service_count = $n_services
local route_per_service = $n_routes

function request()
  -- generate random URLs, some of which may yield non-200 response codes
  local random_consumer = rand(consumer_count)
  local random_service = rand(service_count)
  local random_route = rand(route_per_service)
  -- Concat the url parts
  url_path = string.format("/s%s-r%s?apikey=consumer-%s", random_service, random_route, random_consumer)
  -- Return the request object with the current URL path
  return wrk.format(nil, url_path, headers)
end
EOF

################################################################################

rm -rf miniperf.nginx.prefix
mkdir -p miniperf.nginx.prefix
mkdir -p miniperf.nginx.prefix/logs
mkdir -p miniperf.nginx.prefix/pids
mkdir -p miniperf.nginx.prefix/conf
cat <<EOF > miniperf.nginx.prefix/conf/nginx.conf
worker_processes auto;

pid pids/nginx.pid;

worker_rlimit_nofile 1024;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    server {
        access_log /dev/null;
        error_log /dev/null;
        listen ${KONG_DEMO_UPSTREAM_PORT};
        location ~ /.* {
            return 200;
        }
    }
}
EOF

openresty -p miniperf.nginx.prefix

################################################################################

wrk_output="miniperf.$scenario.wrk.log"
if [ "$1" = "noise" ]
then
   wrk_output="miniperf.$scenario.noise.wrk.log"
fi

echo "----------------------------------------" >> $wrk_output
date >> $wrk_output
echo "----------------------------------------" >> $wrk_output
git branch | grep \* | cut -d ' ' -f2 >> $wrk_output
git log | head -n 1 >> $wrk_output
echo "----------------------------------------" >> $wrk_output

if [ "$1" = "noise" ]
then
(
   for (( i = 1; i < wrk_count * wrk_duration * 10; i ++ ))
   do
      sleep 0.1
      route_name=noise-r$i
      curl $KONG_ADMIN/services/service-1/routes -d "name=$route_name" -d "paths[]=/$route_name" &> $curl_output
      curl $KONG_ADMIN/routes/$route_name/plugins -d "name=key-auth" &> $curl_output
   done
) &
fi


echo -n "Performing requests..."
for (( i = 1; i <= wrk_count; i++ ))
do
   echo -n "."
   wrk -c $wrk_conns -t $wrk_threads -d ${wrk_duration}s -s miniperf.wrk.lua ${KONG_PROXY} >> $wrk_output
   echo >> $wrk_output
done
echo

cat $wrk_output

echo $scenario > .miniperf.again

################################################################################

pkill openresty

[ "$OS" = "Linux" ] && {
   echo $old_governor | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor &> /dev/null
}

