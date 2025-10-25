#!/bin/bash

base="$(dirname "$(readlink -f -- "$0")")/.."
cd "$base" || exit

#Usage: fail <file> <message> [ignore string]
fail() {
    ignoreCheckPath="$1"
    if [ -d "$ignoreCheckPath" ];then
        ignoreCheckPath="$1/AndroidManifest.xml"
    fi
	if [ -z "$3" ] || ! grep -qF "$3" "$ignoreCheckPath";then
		echo "Fatal: $1: $2"
		touch fail
	else
		echo "Warning: $1: $2"
	fi
}

#Keep knownKeys
rm -f tests/priorities fail
touch tests/priorities tests/knownKeys
find . -name AndroidManifest.xml |while read -r manifest;do
	folder="$(dirname "$manifest")"
	#Ensure this overlay doesn't override blacklist-ed properties
	cat tests/blacklist |while read -r b;do
		if grep -qRF "\"$b\"" "$folder";then
			fail "$folder" "Overlay $folder is defining $b which is forbidden" "SUPER OVERLAY"
		fi
	done

	#Everything after that is specifically for static overlays, targetting framework-res
	isStatic="$(xmlstarlet sel -t -m '//overlay' -v @android:isStatic -n "$manifest")"
	[ "$isStatic" != "true" ] && continue

    targetPkg="$(xmlstarlet sel -t -m '//overlay' -v @android:targetPackage -n "$manifest")"
    [ "$targetPkg" != "android" ] && continue

	#Ensure priorities unique-ness
	priority="$(xmlstarlet sel -t -m '//overlay' -v @android:priority -n "$manifest")"
	if grep -qE '^'"$priority"'$' tests/priorities;then
		fail "$manifest" "priority $priority conflicts with another manifest"
	fi
	echo "$priority" >> tests/priorities

	systemPropertyName="$(xmlstarlet sel -t -m '//overlay' -v @android:requiredSystemPropertyName -n "$manifest")"
	if [ "$systemPropertyName" == "ro.vendor.product.name" ] || [ "$systemPropertyName" == "ro.vendor.product.device" ];then
		fail "$manifest" "ro.vendor.product.* is deprecated. Please use ro.vendor.build.fingerprint" \
			'TESTS: Ignore ro.vendor.product.'
	fi

    if grep -qF '$(TARGET_OUT)' "$folder/Android.mk";then
        fail "$folder/Android.mk" "is wrongly pushing overlay in system/overlay rather than product/overlay"
    fi

	#Ensure the overloaded properties exist in AOSP
	find "$folder" -name \*.xml |while read -r xml;do
		keys="$(xmlstarlet sel -t -m '//resources/*' -v @name -n "$xml")"
		for key in $keys;do
			grep -qE '^'"$key"'$' tests/knownKeys && continue
			#Run the ag only on phh's machine. Assume that knownKeys is full enough.
			#If it's enough, ask phh to update it
			if [ -d /nvme2/AOSP-15.a/ ] && \
				(ag '"'"$key"'"' /nvme2/AOSP-15.a/frameworks/base/core/res/res || \
				ag '"'"$key"'"' /build/AOSP-8.1/frameworks/base/core/res/res)> /dev/null ;then
				echo "$key" >> tests/knownKeys
			else
				fail "$xml" "defines a non-existing attribute $key" "I swear it makes sense to set $key, and I can completely explain why."
			fi
		done
	done

    # If overlay has automatic brightness enabled, it's supposed to also include values for it
    if grep -qE 'config_automatic_brightness_available.*true' -r "$folder";then
        if ! grep -r -q -e config_autoBrightnessLcdBacklightValues -e config_autoBrightnessDisplayValuesNits "$folder";then
            fail "$folder" "tries to enable automatic brightness, without actually setting it up"
        fi
    fi

    # Ensure power profile only contain expected types
    f="$folder"/res/xml/power_profile.xml
    if [ -f "$f" ];then
        if xmlstarlet sel -t -m '//*' -v 'name()' -n "$f" |sort -u |grep -qvE '^(array|device|item|value|modem|sleep|idle|active|receive|transmit)';then
            fail "$f" "sets non-sense power-profile values"
        fi
        if [ "$(xmlstarlet sel -t -m '//item[@name="battery.capacity"]' -v . -n "$f")" = 1000 ];then
            fail "$f" "a 1000mAh battery? Sounds wrong."
        fi
    fi

    # Ensure user didn't left some public.xml
	find "$folder" -name \*.xml |while read -r xml;do
        if xmlstarlet sel -t -m '//public' -c . "$xml" |grep -qE ..;then
            fail "$xml" "declares public.xml"
        fi
    done
    if find "$folder" -name color_extraction.xml |grep -qE ..;then
        fail "$folder" "sets color_extraction.xml"
    fi
done

#Help handling with priorities
lastpriority="$(sort -n tests/priorities |grep -E '^[0-9]{2,3}$' | tail -n 1)"
echo 'Note: First high continuous priority available is' $((lastpriority+1))
while true;do
    #We want numbers ranging from 10 to (lastpriority+20)
    v=$((RANDOM%(lastpriority+10)))
    v=$((v+10))
    if ! grep -qE '\b'$v'\b' tests/priorities;then
        echo -e '\tI recommend you use priority' $v
        break
    fi
done
rm -f tests/priorities

#find -name \*.xml |xargs dos2unix -ic |while read f;do
#	fail $f "File is DOS type"
#done

#Check overlay.mk
(
	sorted="$(tail -n +2 overlay.mk |grep -E treble- | LC_ALL=C sort -s | md5sum)"
	unsorted="$(tail -n +2 overlay.mk |grep -E treble- | md5sum)"
	if [ "$sorted" != "$unsorted" ];then
		fail overlay.mk "Keep entries sorted"
	fi
	if grep -E '.+' overlay.mk |grep -qvE '\\$';then
		fail overlay.mk "Keep the \\ at the end of all non-empty lines"
	fi
	if [ "$(tail -n 1 overlay.mk)" != "" ];then
		fail overlay.mk "Keep the empty line at the end"
	fi
)

#Check overlay.mk has all overlays
(
    echo "Checking if overlay.mk lists all defined overlays..."
    
    defined_packages=$(mktemp)
    listed_packages=$(mktemp)
    
    # Find all .mk files, grep for the definition line, then use awk to reliably extract the package name.
    # awk is much more portable and reliable for this than complex sed. It prints the 4th field.
    find . -name "*.mk" | xargs grep "LOCAL_PACKAGE_NAME *:=" | awk '{print $4}' | grep 'treble-overlay' | sort -u > "$defined_packages"
    
    # Extract from overlay.mk. Using grep and awk is also safer here.
    grep 'treble-overlay' < overlay.mk | awk '{print $1}' | sort -u > "$listed_packages"
    
    # Use comm to find differences
    missing_from_mk=$(comm -23 "$defined_packages" "$listed_packages")
    unnecessary_in_mk=$(comm -13 "$defined_packages" "$listed_packages")

    has_error=false
    if [ -n "$missing_from_mk" ]; then
        echo "Fatal: overlay.mk: The following overlays are defined in .mk files but are NOT listed in overlay.mk:"
        echo "$missing_from_mk"
        has_error=true
    fi

    if [ -n "$unnecessary_in_mk" ]; then
        echo "Fatal: overlay.mk: The following overlays are listed in overlay.mk but their definition was NOT found:"
        echo "$unnecessary_in_mk"
        has_error=true
    fi

    if [ "$has_error" = true ]; then
        touch fail
    else
        echo "Check passed: overlay.mk is perfectly in sync with project definitions."
    fi

    # Clean up
    rm "$defined_packages" "$listed_packages"
)

if [ -f fail ];then exit 1; fi
