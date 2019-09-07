import UIKit


public enum Operations: Swift.Error {
    case fetchFail
    case deletaFail
    case saveFail
    case loadFail
    case folderCreation
}


public enum ExpiryDate {
    case never
    case everyDay
    case everyWeek
    case everyMonth
    case seconds(TimeInterval)

    public var date: Date {
        switch self {
        case .never:

            return Date.distantFuture
        case .everyDay:

            return endOfDay
        case .everyWeek:

            return date(afterDays: 7)
        case .everyMonth:

            return date(afterDays: 30)
        case let .seconds(seconds):

            return Date().addingTimeInterval(seconds)
        }
    }

   
    private func date(afterDays days: Int) -> Date {
        return Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }

    private var endOfDay: Date {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        var components = DateComponents()
        components.day = 1
        components.second = -1

        return Calendar.current.date(byAdding: components, to: startOfDay) ?? Date()
    }
}

public class Cachy: NSCache<AnyObject, AnyObject> {

    public static var shared: Cachy {
        struct Static {
            static var instance = Cachy() {
                didSet {
                    Static.instance.countLimit = Cachy.elementsCount
                    Static.instance.totalCostLimit = Cachy.elementsCostLimit
                }
            }
        }

        return Static.instance
    }

    // MARK: - Static properties

    /// Static property to store the count of element stored in the cache (by default it is 100)
    public static var elementsCount = 100

    /// Static property to store the cost limit of the cache (by default it is 0)
    public static var elementsCostLimit = 0

    /// Static property to indicate wether the cached objects will be added to the disk storage or not
    public static var isOnlyInMemory = false

    // MARK: - Public properties

    /// Public property to store the expiration date of each object in the cache (by default it is set to .never)
    open var expiration: ExpiryDate = .never

    // MARK: - Public methods

    /// Public method to add an object to the cache
    ///
    /// - Parameter object: The object which will be added to the cache
    open func add(object: CachyObject) {
        var objects = self.object(forKey: cacheKey as AnyObject) as? [CachyObject]

        if objects?.contains(where: { $0.key == object.key }) == false {
            objects?.append(object)

            set(object: objects as AnyObject)
        } else {
            update(object: object)
        }

        if !Cachy.isOnlyInMemory {
            try? save(object: object)
        }
    }

    ///
    /// - Parameter key: The key of the searched object
    /// - Returns: The object found under the given key ot nil
    open func get<T>(forKey key: String) -> T? {
        let objects = object(forKey: cacheKey as AnyObject) as? [CachyObject]

        let objectsOfType = objects?.filter { $0.value is T }

        return objectsOfType?.filter { $0.key == key }.first?.value as? T
    }

    /// Public method to update an existing object
    ///
    /// - Parameter object: The new object
    open func update(object: CachyObject) {
        var objects = self.object(forKey: cacheKey as AnyObject) as? [CachyObject]

        if let index = objects?.firstIndex(where: { $0.key == object.key }) {
            objects?.remove(at: index)
            objects?.append(object)
        }

        set(object: objects as AnyObject)
    }

    ///
    /// - : An error if such occures during save
    @available(*, deprecated, message: "The library automaticaly saves cached objects to the disk if the property isOnlyInMemory is false")
    open func save() throws {
        let objects = object(forKey: cacheKey as AnyObject) as? [CachyObject] ?? [CachyObject]()
        let fileManager = FileManager.default
        do {
            let cacheDirectory = try fileManager.url(for: .cachesDirectory, in: .allDomainsMask, appropriateFor: nil, create: false)
            let fileDirectory = cacheDirectory.appendingPathComponent("spacekit")

            var fileDir = fileDirectory.absoluteString
            let range = fileDir.startIndex ..< fileDir.index(fileDir.startIndex, offsetBy: 7)
            fileDir.removeSubrange(range)

            try createFolderIfNeeded(atPath: fileDir, absolutePath: fileDirectory)

            for object in objects {
                let fileFormatedName = object.key.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? object.key
                let fileName = fileDirectory.appendingPathComponent(fileFormatedName)

                let data = NSKeyedArchiver.archivedData(withRootObject: object)

                try? data.write(to: fileName)
            }

            set(object: objects as AnyObject)
        } catch {
            throw Operations.saveFail
        }
    }

    // MARK: - Initialize/Livecycle methods

    override init() {
        super.init()

        loadCache()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationIsActivating(notification:)), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Override methods

    // MARK: - Private properties

    /// read only private property to store the identifier of the read/write queue
    private let cacheKey = Bundle.main.bundleIdentifier ?? ""

    /// private property to store a lock for conqurency
    private let lock = NSLock()

    // MARK: - Private methods

    /// Private method to create the cache folder if it doesn't exist
    ///
    /// - Parameter path: The path where the folder will be created
    private func createFolderIfNeeded(atPath path: String, absolutePath: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        do {
            if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                try fileManager.createDirectory(at: absolutePath, withIntermediateDirectories: false, attributes: nil)
            }
        } catch {
            throw Operations.folderCreation
        }
    }

    /// Private method to set object to the cache
    ///
    /// - Parameter object: The object to be added to the cache
    private func set(object: AnyObject) {
        lock.lock()
        setObject(object, forKey: cacheKey as AnyObject)
        lock.unlock()
    }

    /// Public method to load all object from disk to memory
    ///
    /// - Throws: An error if such occures during load
    private func load() throws {
        let fileManager = FileManager.default
        do {
            let cacheDirectory = try fileManager.url(for: .cachesDirectory, in: .allDomainsMask, appropriateFor: nil, create: false)
            let fileDirectory = cacheDirectory.appendingPathComponent("spacekit")

            var fileDir = fileDirectory.absoluteString
            let range = fileDir.startIndex ..< fileDir.index(fileDir.startIndex, offsetBy: 7)
            fileDir.removeSubrange(range)

            try createFolderIfNeeded(atPath: fileDir, absolutePath: fileDirectory)

            let paths = try fileManager.contentsOfDirectory(atPath: fileDir)

            for path in paths {
                if let object = NSKeyedUnarchiver.unarchiveObject(withFile: fileDir + path) as? CachyObject {
                    if !object.isExpired {
                        add(object: object)
                    } else {
                        try? fileManager.removeItem(atPath: fileDir + path)
                    }
                }
            }
        } catch {
            throw Operations.loadFail
        }
    }

    /// Private method to store a cached object on the disk
    ///
    /// - Parameter object: The object which will be stored
    /// - Throws: A possible error during save
    private func save(object: CachyObject) throws {
        let fileManager = FileManager.default

        do {
            let cacheDirectory = try fileManager.url(for: .cachesDirectory, in: .allDomainsMask, appropriateFor: nil, create: false)
            let fileDirectory = cacheDirectory.appendingPathComponent("spacekit")

            var fileDir = fileDirectory.absoluteString
            let range = fileDir.startIndex ..< fileDir.index(fileDir.startIndex, offsetBy: 7)
            fileDir.removeSubrange(range)

            try createFolderIfNeeded(atPath: fileDir, absolutePath: fileDirectory)

            let fileFormatedName = object.key.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? object.key

            let convertedFileName = convertToBase64(withString: fileFormatedName).suffix(45).map { String($0) }.joined()

            let fileName = fileDirectory.appendingPathComponent(convertedFileName)

            if !fileManager.fileExists(atPath: fileName.absoluteString) || object.isUpdated {
                let data = NSKeyedArchiver.archivedData(withRootObject: object)

                try? data.write(to: fileName)
            }
        } catch {
            throw Operations.saveFail
        }
    }

    /// Private method to load the cache
    private func loadCache() {
        set(object: [CachyObject]() as AnyObject)
        try? load()
    }

    /// Private method to convert a string to base 64 encoded string
    ///
    /// - Parameter withString: The string to be conferted
    /// - Returns: The base 64 encoded string
    private func convertToBase64(withString: String) -> String {
        return Data(withString.utf8).base64EncodedString()
    }

    /// Private method to handle notifications for active application state
    ///
    /// - Parameter notification: A notification send by the OS
    @objc private func applicationIsActivating(notification _: Notification) {
        loadCache()
    }
}
