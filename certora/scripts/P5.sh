#!/bin/bash

certora/scripts/apply-patch.sh
certoraRun certora/confs/properties/P5_P9.conf
certora/scripts/remove-patch.sh