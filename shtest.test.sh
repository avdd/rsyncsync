#!/bin/bash

trivially_pass() {
    true
}

a_theorem() {
    given trivially_pass
    true
}

cascading_theorem() {
    given a_theorem
    true
}

has_THIS() {
    test "$THIS"
}

this_is_pwd() {
    test "$THIS" = "$PWD"
}

# the following tests all fail

fail() {
    false
}

fail_after_test_undefined() {
    fail
}

fail_given_nonsense() {
    given nonsense
}

fail_cascades() {
    given fail_given_nonsense
}

fail_if_given_twice() {
    given trivially_pass
    given a_theorem
}

