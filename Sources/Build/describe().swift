/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import func POSIX.getenv
import func POSIX.mkdir
import PackageType
import Utility

/**
  - Returns: path to generated YAML for consumption by the llbuild based swift-build-tool
*/
public func describe(prefix: String, _ conf: Configuration, _ modules: [Module], _ products: [Product], Xcc: [String], Xld: [String], Xswiftc: [String]) throws -> String {

    guard modules.count > 0 else {
        fatalError("No modules input")  //TODO throw
    }

    let Xcc = Xcc.flatMap{ ["-Xcc", $0] } + extraImports()
    let Xld = Xld.flatMap{ ["-Xlinker", $0] }
    let prefix = try mkdir(prefix, conf.dirname)
    let yaml = try YAML(path: "\(prefix).yaml")
    let write = yaml.write
    let (tests, nontests) = targetSplitter(modules, products)

    defer { yaml.close() }

    try write("client:")
    try write("  name: swift-build")
    try write("tools: {}")
    try write("targets:")
    try write("  default: ", nontests)
    try write("  test: ", tests)
    try write("commands: ")

    var mkdirs = Set<String>()


    let swiftcArgs = Xcc + Xswiftc

    for case let module as SwiftModule in modules {

        let otherArgs = swiftcArgs + module.Xcc + platformArgs() + [conf.define]

        switch conf {
        case .Debug:
            var args = ["-j8","-Onone","-g","-D","SWIFT_PACKAGE"]
            args.append("-enable-testing")

        #if os(OSX)
            //TODO if this fails and is required, throw
            if let platformPath = Resources.path.platformPath {
                let path = Path.join(platformPath, "Developer/Library/Frameworks")
                args += ["-F", path]
            }
        #endif

            let node = IncrementalNode(module: module, prefix: prefix)

            try write("  ", module.targetName, ":")
            try write("    tool: swift-compiler")
            try write("    executable: ", Resources.path.swiftc)
            try write("    module-name: ", module.c99name)
            try write("    module-output-path: ", node.moduleOutputPath)
            try write("    inputs: ", node.inputs)
            try write("    outputs: ", node.outputs)
            try write("    import-paths: ", prefix)
            try write("    temps-path: ", node.tempsPath)
            try write("    objects: ", node.objectPaths)
            try write("    other-args: ", args + otherArgs)
            try write("    sources: ", module.sources.paths)

            // this must be set or swiftc compiles single source file
            // modules with a main() for some reason
            try write("    is-library: ", module.isLibrary)

            for o in node.objectPaths {
                mkdirs.insert(o.parentDirectory)
            }

        case .Release:
            let inputs = module.dependencies.map{ $0.targetName } + module.sources.paths
            var args = ["-c", "-emit-module", "-D", "SWIFT_PACKAGE", "-O", "-whole-module-optimization", "-I", prefix] + swiftcArgs
            let productPath = Path.join(prefix, "\(module.c99name).o")

            if module.isLibrary {
                args += ["-parse-as-library"]
            }

            try write("  ", module.targetName, ":")
            try write("    tool: shell")
            try write("    description: Compiling \(module.name)")
            try write("    inputs: ", inputs)
            try write("    outputs: ", [productPath, module.targetName])
            try write("    args: ", [Resources.path.swiftc, "-o", productPath] + args + module.sources.paths + otherArgs)
        }
    }

    // make eg .build/debug/foo.build/subdir for eg. Sources/foo/subdir/bar.swift
    // TODO swift-build-tool should do this
    for dir in mkdirs {
        try mkdir(dir)
    }

    for product in products {

        let outpath = Path.join(prefix, product.outname)

        let objects: [String]
        switch conf {
        case .Release:
            objects = product.buildables.map{ Path.join(prefix, "\($0.c99name).o") }
        case .Debug:
            objects = product.buildables.flatMap{ return IncrementalNode(module: $0, prefix: prefix).objectPaths }
        }

        var args = [Resources.path.swiftc] + swiftcArgs

        switch product.type {
        case .Library(.Static):
            fatalError("Unimplemented")
        case .Test:
            #if os(OSX)
                args += ["-Xlinker", "-bundle"]

                //TODO if this fails and is required, throw
                if let platformPath = Resources.path.platformPath {
                    let path = Path.join(platformPath, "Developer/Library/Frameworks")
                    args += ["-F", path]
                }

                // TODO should be llbuild rules
                if conf == .Debug {
                    try mkdir(outpath.parentDirectory)
                    try fopen(outpath.parentDirectory.parentDirectory, "Info.plist", mode: .Write) { fp in
                        try fputs(infoPlist(product), fp)
                    }
                }
            #else
                //HACK
                let hack1 = product.modules.flatMap{ $0 as? TestModule }.first!
                let hack2 = hack1.sources.root.parentDirectory
                let hack3 = Path.join(hack2, "LinuxMain.swift")
                args.append(hack3)

                args.append("-emit-executable")
                args += ["-I", prefix]
            #endif
        case .Library(.Dynamic):
            args.append("-emit-library")
        case .Executable:
            args.append("-emit-executable")
            if conf == .Release {
                 args += ["-Xlinker", "-dead_strip"]
            }
        }

        args += platformArgs() //TODO don't need all these here or above: split outname
        args += Xld
        args += ["-o", outpath]
        args += objects

        let inputs = product.modules.flatMap{ [$0.targetName] + IncrementalNode(module: $0, prefix: prefix).inputs }

        try write("  \(product.targetName):")
        try write("    tool: shell")
        try write("    description: Linking \(product)")
        try write("    inputs: ", inputs)
        try write("    outputs: ", [product.targetName, outpath])
        try write("    args: ", args)
    }

    return yaml.path
}


extension Product {
    private var buildables: [SwiftModule] {
        return recursiveDependencies(modules.map{$0}).flatMap{ $0 as? SwiftModule }
    }
}

private func extraImports() -> [String] {
    //FIXME HACK
    if let I = getenv("SWIFTPM_EXTRA_IMPORT") {
        return ["-I", I]
    } else {
        return []
    }
}
