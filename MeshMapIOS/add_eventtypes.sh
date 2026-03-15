#!/bin/bash

cd "/Users/webb/Library/CloudStorage/OneDrive-Vanderbilt/Vanderbilt/2026 Spring UNSW/MeshMapMVP"

# Add EventTypesConfig.swift to PBXBuildFile section
sed -i '' '/A1000011 \/\* MeshImageUtils.swift in Sources \*/ = {isa = PBXBuildFile; fileRef = A2000011 \/\* MeshImageUtils.swift \*\/; };/a\
\t\t\tA1000012 /* EventTypesConfig.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000012 /* EventTypesConfig.swift */; };' MeshChatMVP.xcodeproj/project.pbxproj

# Add EventTypesConfig.swift to PBXFileReference section  
sed -i '' '/A2000011 \/\* MeshImageUtils.swift \*/ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MeshImageUtils.swift; sourceTree = "<group>"; };/a\
\t\t\tA2000012 /* EventTypesConfig.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EventTypesConfig.swift; sourceTree = "<group>"; };' MeshChatMVP.xcodeproj/project.pbxproj

# Add to the build phase sources
sed -i '' '/A1000011 \/\* MeshImageUtils.swift in Sources \*/,/a\
\t\t\t\t\tA1000012 /* EventTypesConfig.swift in Sources */,' MeshChatMVP.xcodeproj/project.pbxproj

# Add to the group
sed -i '' '/A2000011 \/\* MeshImageUtils.swift \*/,/a\
\t\t\t\t\tA2000012 /* EventTypesConfig.swift */,' MeshChatMVP.xcodeproj/project.pbxproj

echo "EventTypesConfig.swift added to project"
