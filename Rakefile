#!/usr/bin/env ruby

require 'xcodeproj'

task :xcodeproj do
  system "swift package generate-xcodeproj"


  project = Xcodeproj::Project.open(Dir["*.xcodeproj"].first)

  add_system_frameworks project, ["HealthKit"]
  add_system_frameworks project, ["WatchKit"]

end

def add_system_frameworks(project, names)

    frameworks_group = project.groups.find { |group| group.display_name == 'Frameworks' }
    target = project.targets.find { |target| target.to_s == 'HealthSyncKit' }
    build_phase = target.build_phases.find { |build_phase| build_phase.to_s == 'FrameworksBuildPhase' }
    framework_group = target.project.frameworks_group

    names.each do |name|
        path = "System/Library/Frameworks/#{name}.framework"
        file_ref = framework_group.new_reference(path)
        file_ref.name = "#{name}.framework"
        file_ref.source_tree = 'SDKROOT'
        build_file = build_phase.add_file_reference(file_ref)
    end

    project.save
end
