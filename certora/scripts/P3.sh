#!/bin/bash

certora/scripts/apply-patch.sh
certoraRun certora/confs/properties/P3-1.conf
certoraRun certora/confs/properties/P3-2.conf
certora/scripts/remove-patch.sh