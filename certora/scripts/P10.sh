#!/bin/bash

certora/scripts/apply-patch.sh
certoraRun certora/confs/properties/P10.conf
certora/scripts/remove-patch.sh