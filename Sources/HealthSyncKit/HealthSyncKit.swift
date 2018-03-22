import HealthKit
import WatchKit

class HealthSyncKit {
    
    private var healthStore: HKHealthStore
    
    lazy var dateFormatter:DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
    
    lazy var filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter();
        formatter.dateFormat = "yyyy-MM-dd hh.mm.ss"
        return formatter;
    }()
    
    init() {
        healthStore = HKHealthStore()
    }
    
    private enum HealthkitSetupError: Error {
        case notAvailableOnDevice
        case dataTypeNotAvailable
    }
    
    func authorizeHealthKit(completion: @escaping (Bool, Error?) -> Swift.Void) {
        
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, HealthkitSetupError.notAvailableOnDevice)
            return
        }
        
        let healthKitTypesToWrite: Set<HKSampleType> = []
        
        let healthKitTypesToRead: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate)!
        ]
        
        HKHealthStore().requestAuthorization(
            toShare: healthKitTypesToWrite,
            read: healthKitTypesToRead
        ){
            (success, error) in
            completion(success, error)
        }
    }
    
    func heartRate(for workout: HKWorkout, completion: @escaping (([HKQuantitySample]?, Error?) -> Swift.Void)){
        var allSamples = Array<HKQuantitySample>()
        
        let hrType = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate)!
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: HKQueryOptions.strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        
        let heartRateQuery = HKSampleQuery(sampleType: hrType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) {
            (query, samples, error) in
            
            guard let heartRateSamples: [HKQuantitySample] = samples as? [HKQuantitySample], error == nil else {
                completion(nil, error)
                return
            }
            if (heartRateSamples.count == 0){
                print("Got no heart rate samples. Too bad")
                completion([HKQuantitySample](), nil);
                return;
            }
            print("Got \(heartRateSamples.count) heart rate samples");
            for heartRateSample in heartRateSamples {
                allSamples.append(heartRateSample)
            }
            DispatchQueue.main.async {
                completion(allSamples, nil)
            }
        }
        healthStore.execute(heartRateQuery)
    }
    
    func route(for workout: HKWorkout, completion: @escaping (([CLLocation]?, Error?) -> Swift.Void)){
        let routeType = HKSeriesType.workoutRoute();
        let p = HKQuery.predicateForObjects(from: workout)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        
        let q = HKSampleQuery(sampleType: routeType, predicate: p, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) {
            (query, samples, error) in
            if let err = error {
                print(err)
                return
            }
            
            guard let routeSamples: [HKWorkoutRoute] = samples as? [HKWorkoutRoute] else { print("No route samples"); return }
            
            if (routeSamples.count == 0){
                completion([CLLocation](), nil)
                return;
            }
            var sampleCounter = 0
            var routeLocations:[CLLocation] = []
            
            for routeSample: HKWorkoutRoute in routeSamples {
                
                let locationQuery: HKWorkoutRouteQuery = HKWorkoutRouteQuery(route: routeSample) { _, locationResults, done, error in
                    guard locationResults != nil else {
                        print("Error occured while querying for locations: \(error?.localizedDescription ?? "")")
                        DispatchQueue.main.async {
                            completion(nil, error)
                        }
                        return
                    }
                    
                    if done {
                        sampleCounter += 1
                        if sampleCounter != routeSamples.count {
                            if let locations = locationResults {
                                routeLocations.append(contentsOf: locations)
                            }
                        } else {
                            if let locations = locationResults {
                                routeLocations.append(contentsOf: locations)
                                let sortedLocations = routeLocations.sorted(by: {$0.timestamp < $1.timestamp})
                                DispatchQueue.main.async {
                                    completion(sortedLocations, error)
                                }
                            }
                        }
                    } else {
                        if let locations = locationResults {
                            routeLocations.append(contentsOf: locations)
                        }
                    }
                }
                
                self.healthStore.execute(locationQuery)
            }
        }
        healthStore.execute(q)
    }
    
    func loadWorkouts(completion: @escaping (([HKWorkout]?, Error?) -> Swift.Void)){
        
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .walking),
            HKQuery.predicateForWorkouts(with: .running),
            HKQuery.predicateForWorkouts(with: .cycling),
            HKQuery.predicateForWorkouts(with: .swimming),
            ])
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ){
            (query, samples, error) in
            DispatchQueue.main.async {
                guard let samples = samples as? [HKWorkout], error == nil else {
                    completion(nil, error)
                    return
                }
                completion(samples, nil)
            }
        }
        healthStore.execute(query)
    }
    
    func export(workout: HKWorkout, completion: @escaping ((URL?, Error?) -> Swift.Void)) {
        
        let workout_name: String = {
            switch workout.workoutActivityType {
            case .cycling: return "Cycle"
            case .running: return "Run"
            case .walking: return "Walk"
            case .swimming: return "Swimming"
            default: return "Workout"
            }
        }()
        let workout_title = "\(workout_name) - \(self.dateFormatter.string(from: workout.startDate))"
        let file_name = "\(self.filenameDateFormatter.string(from: workout.startDate)) - \(workout_name)"
        
        let ext = (workout_name == "Swimming" ? "tcx" : "gpx");
        
        let targetURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(file_name)
            .appendingPathExtension(ext)
        
        let file: FileHandle
        
        do {
            let manager = FileManager.default;
            if manager.fileExists(atPath: targetURL.path){
                try manager.removeItem(atPath: targetURL.path)
            }
            print(manager.createFile(atPath: targetURL.path, contents: Data()))
            file = try FileHandle(forWritingTo: targetURL);
        }catch let err {
            completion(nil, err)
            return
        }
        
        self.heartRate(for: workout) {
            (rates, error) in
            
            guard let keyedRates = rates, error == nil else {
                completion(nil, error)
                return
            }
            
            let iso_formatter = ISO8601DateFormatter()
            var current_heart_rate_index = 0;
            var current_hr: Double = -1;
            let bpm_unit = HKUnit(from: "count/min")
            var hr_string = "";
            
            switch workout.workoutActivityType {
            case .swimming:
                file.write(
                    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><TrainingCenterDatabase xsi:schemaLocation=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 https://www8.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd\" xmlns:ns5=\"http://www.garmin.com/xmlschemas/ActivityGoals/v1\" xmlns:ns3=\"http://www.garmin.com/xmlschemas/ActivityExtension/v2\" xmlns:ns2=\"http://www.garmin.com/xmlschemas/UserProfile/v2\" xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:ns4=\"http://www.garmin.com/xmlschemas/ProfileExtension/v1\"><Activities><Activity Sport=\"Other\"><Id>\(iso_formatter.string(from: workout.startDate))</Id>".data(using: .utf8)!
                )
                
                var openWater = false
                let segments = workout.workoutEvents!.filter { $0.type == HKWorkoutEventType.segment }
                
                self.route(for: workout) {
                    (maybe_locations, error) in
                    guard let locations = maybe_locations, error == nil else {
                        file.closeFile()
                        completion(nil, error)
                        return
                    }
                    
                    openWater = !locations.isEmpty
                    
                    for segment in segments {
                        let heartRates = rates!.filter { $0.startDate >= segment.dateInterval.start && $0.endDate <= segment.dateInterval.end }
                        var lastLocation : CLLocation? = nil
                        let segLocations = locations.filter { $0.timestamp >= segment.dateInterval.start && $0.timestamp <= segment.dateInterval.end }
                        
                        if !segLocations.isEmpty {
                            openWater = true
                            var totalDistance = 0.0
                            for location in segLocations {
                                if lastLocation != nil {
                                    totalDistance += location.distance(from: lastLocation!)
                                }
                                lastLocation = location
                            }
                            lastLocation = nil
                            file.write(
                                "<Lap StartTime=\"\(iso_formatter.string(from: segment.dateInterval.start))\"><TotalTimeSeconds>\(segment.dateInterval.duration)</TotalTimeSeconds><DistanceMeters>\(totalDistance)</DistanceMeters><Calories>0</Calories><Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>".data(using: .utf8)!
                            )
                            
                            totalDistance = 0.0
                            for location in segLocations {
                                let hr = heartRates.filter { $0.startDate >= location.timestamp && $0.endDate <= location.timestamp }
                                var hrVal: Double? = 0.0
                                if (!hr.isEmpty) {
                                    hrVal = hr.first?.quantity.doubleValue(for: bpm_unit)
                                }
                                if lastLocation != nil {
                                    totalDistance += location.distance(from: lastLocation!)
                                }
                                file.write(
                                    "<Trackpoint><Time>\(iso_formatter.string(from: location.timestamp))</Time><Position><LatitudeDegrees>\(location.coordinate.latitude)</LatitudeDegrees><LongitudeDegrees>\(location.coordinate.longitude)</LongitudeDegrees></Position><DistanceMeters>\(String(format:"%f", totalDistance))</DistanceMeters><HeartRateBpm><Value>\(String(format:"%f", hrVal!))</Value></HeartRateBpm><Extensions><ns3:TPX><ns3:Speed>\(location.speed)</ns3:Speed></ns3:TPX></Extensions></Trackpoint>".data(using: .utf8)!
                                )
                                lastLocation = location
                            }
                            
                            file.write("</Track></Lap>".data(using: .utf8)!)
                        }
                    }
                    
                    if !openWater {
                        let poolDistance = workout.metadata!["HKLapLength"] as! HKQuantity
                        
                        var totalDistance = poolDistance.doubleValue(for: HKUnit.meter())
                        for segment in segments {
                            let laps = workout.workoutEvents!.filter { $0.type == HKWorkoutEventType.lap && $0.dateInterval.start >= segment.dateInterval.start && $0.dateInterval.end <= segment.dateInterval.end }
                            
                            file.write(
                                "<Lap StartTime=\"\(iso_formatter.string(from: segment.dateInterval.start))\"><TotalTimeSeconds>\(segment.dateInterval.duration)</TotalTimeSeconds><DistanceMeters>\(poolDistance.doubleValue(for: HKUnit.meter()) * Double(laps.count))</DistanceMeters><Calories>0</Calories><Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>".data(using: .utf8)!
                            )
                            
                            let heartRates = rates!.filter { $0.startDate >= segment.dateInterval.start && $0.endDate <= segment.dateInterval.end }
                            for lap in laps {
                                var startTrackTime = lap.dateInterval.start
                                while startTrackTime <= lap.dateInterval.end {
                                    startTrackTime.addTimeInterval(1)
                                    
                                    let hr = heartRates.filter { $0.startDate >= startTrackTime && $0.endDate <= startTrackTime }
                                    var hrVal: Double? = 0.0
                                    if (!hr.isEmpty) {
                                        hrVal = hr.first?.quantity.doubleValue(for: bpm_unit)
                                    }
                                    var distance = 0.0
                                    if startTrackTime > lap.dateInterval.end {
                                        distance = totalDistance
                                        totalDistance += poolDistance.doubleValue(for: HKUnit.meter())
                                    }
                                    file.write(
                                        "<Trackpoint><Time>\(iso_formatter.string(from: startTrackTime))</Time><DistanceMeters>\(distance)</DistanceMeters><HeartRateBpm><Value>\(String(format:"%f", hrVal!))</Value></HeartRateBpm><Extensions><ns3:TPX><ns3:Speed>0.0</ns3:Speed></ns3:TPX></Extensions></Trackpoint>".data(using: .utf8)!
                                    )
                                }
                            }
                            file.write("</Track></Lap>".data(using: .utf8)!)
                        }
                    }
                    
                    file.write("<Notes><![CDATA[\(workout_title)]]></Notes></Activity></Activities></TrainingCenterDatabase>".data(using: .utf8)!)
                    file.closeFile()
                    
                    completion(targetURL, nil)
                }
                break;
            default:
                file.write(
                    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"Apple Workouts (via pilif's hack of the week)\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns=\"http://www.topografix.com/GPX/1/1\" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\" xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\"><trk><name><![CDATA[\(workout_title)]]></name><time>\(iso_formatter.string(from: workout.startDate))</time><trkseg>".data(using: .utf8)!
                )
                
                self.route(for: workout){
                    (maybe_locations, error) in
                    guard let locations = maybe_locations, error == nil else {
                        print(error as Any);
                        file.closeFile()
                        return
                    }
                    
                    for location in locations {
                        while (current_heart_rate_index < keyedRates.count) && (location.timestamp > keyedRates[current_heart_rate_index].startDate) {
                            current_hr = keyedRates[current_heart_rate_index].quantity.doubleValue(for: bpm_unit)
                            current_heart_rate_index += 1;
                            hr_string = "<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(current_hr)</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"
                        }
                        
                        file.write(
                            "<trkpt lat=\"\(location.coordinate.latitude)\" lon=\"\(location.coordinate.longitude)\"><ele>\(location.altitude.magnitude)</ele><time>\(iso_formatter.string(from: location.timestamp))</time>\(hr_string)</trkpt>"
                                .data(using: .utf8)!
                        )
                    }
                    file.write("</trkseg></trk></gpx>".data(using: .utf8)!)
                    file.closeFile()
                    
                    completion(targetURL, nil)
                }
                break;
            }
        }
    }
}
