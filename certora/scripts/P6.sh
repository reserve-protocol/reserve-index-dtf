#!/bin/bash

certora/scripts/apply-patch.sh
certoraRun certora/confs/properties/P6.conf
certoraRun certora/confs/properties/P6-2.conf
certora/scripts/remove-patch.sh