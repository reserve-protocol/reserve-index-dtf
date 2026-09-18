#!/bin/bash

certora/scripts/apply-patch.sh
certoraRun certora/confs/properties/P4-1.conf
certoraRun certora/confs/properties/P4-2.conf
certoraRun certora/confs/properties/P4-3.conf
certora/scripts/remove-patch.sh