#!/bin/bash

certora/scripts/apply-patch.sh
certoraRun certora/confs/properties/P8.conf
certora/scripts/remove-patch.sh