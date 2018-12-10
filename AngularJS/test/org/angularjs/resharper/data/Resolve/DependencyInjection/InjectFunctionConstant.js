// Copyright 2000-2018 JetBrains s.r.o. Use of this source code is governed by the Apache 2.0 license that can be found in the LICENSE file.
module.constant('myConstantFunc', function(name) {
    return "Hello " + name;
});

module.controller('myController', function(myConstantFunc) {
    return myConstantFunc('Matt');
});
