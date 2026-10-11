#!/bin/bash

certora/scripts/apply-patch.sh

certoraRun certora/confs/folio_prerequisities.conf

for FILE in certora/confs/properties/*.conf
do
    echo ${FILE}
    certoraRun ${FILE}
done

certora/scripts/remove-patch.sh