#!/bin/bash
# Prints the PRIVATE update-signing key so you can store it in a password manager.
# Run it yourself, and never paste the output anywhere else.
security find-generic-password -a feather-update-signing -s dev.feather.update-key -w
