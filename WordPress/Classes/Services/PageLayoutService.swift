import UIKit
import CoreData

class PageLayoutService {
    private struct Parameters {
        static let previewWidth = "preview_width"
        static let scale = "scale"
    }

    typealias CompletionHandler = (Swift.Result<GutenbergPageLayouts, Error>) -> Void

    static func layouts(forBlog blog: Blog, withThumbnailSize thumbnailSize: CGSize, completion: @escaping CompletionHandler) {
        if blog.isAccessibleThroughWPCom() {
            fetchWordPressComLayouts(forBlog: blog, withThumbnailSize: thumbnailSize, completion: completion)
        } else {
            fetchSharedLayouts(thumbnailSize, completion: completion)
        }
    }

    private static func fetchWordPressComLayouts(forBlog blog: Blog, withThumbnailSize thumbnailSize: CGSize, completion: @escaping CompletionHandler) {
        guard let blogId = blog.dotComID as? Int, let api = blog.wordPressComRestApi() else {
            let error = NSError(domain: "PageLayoutService", code: 0, userInfo: [NSDebugDescriptionErrorKey: "Api or dotCom Site ID not found"])
            completion(.failure(error))
            return
        }

        let urlPath = "/wpcom/v2/sites/\(blogId)/block-layouts"
        fetchLayouts(thumbnailSize, api, urlPath, completion)
    }

    private static func fetchSharedLayouts(_ thumbnailSize: CGSize, completion: @escaping CompletionHandler) {
        let api = WordPressComRestApi.anonymousApi(userAgent: WPUserAgent.wordPress())
        let urlPath = "/wpcom/v2/common-block-layouts"
        fetchLayouts(thumbnailSize, api, urlPath, completion)
    }

    private static func fetchLayouts(_ thumbnailSize: CGSize, _ api: WordPressComRestApi, _ urlPath: String, _ completion: @escaping CompletionHandler) {
        api.GET(urlPath, parameters: parameters(thumbnailSize), success: { (responseObject, _) in
            guard let result = parseLayouts(fromResponse: responseObject) else {
                let error = NSError(domain: "PageLayoutService", code: 0, userInfo: [NSDebugDescriptionErrorKey: "Unable to parse response"])
                completion(.failure(error))
                return
            }

            persistToCoreData(result) { (persistanceResult) in
                switch persistanceResult {
                case .success:
                    completion(.success(result))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }, failure: { (error, _) in
            completion(.failure(error))
        })
    }

    private static func parseLayouts(fromResponse response: Any) -> GutenbergPageLayouts? {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            return nil
        }
        return try? JSONDecoder().decode(GutenbergPageLayouts.self, from: data)
    }

    // Parameter Generation
    private static func parameters(_ thumbnailSize: CGSize) -> [String: AnyObject] {
        return [
            Parameters.previewWidth: previewWidth(thumbnailSize) as AnyObject,
            Parameters.scale: scale as AnyObject
        ]
    }

    private static func previewWidth(_ thumbnailSize: CGSize) -> String {
        return "\(thumbnailSize.width)"
    }

    private static let scale = UIScreen.main.nativeScale
}

extension PageLayoutService {

    static func resultsController() -> NSFetchedResultsController<PageTemplateCategory> {
        let context = ContextManager.shared.mainContext
        let request: NSFetchRequest<PageTemplateCategory> = PageTemplateCategory.fetchRequest()
        let sort = NSSortDescriptor(key: "title", ascending: true)
        request.sortDescriptors = [sort]

        let resultsController = NSFetchedResultsController<PageTemplateCategory>(fetchRequest: request, managedObjectContext: context, sectionNameKeyPath: nil, cacheName: nil)

        do {
            try resultsController.performFetch()
        } catch {
            DDLogError("Failed to fetch entities: \(error)")
        }

        return resultsController
    }

    private static func persistToCoreData(_ layouts: GutenbergPageLayouts, _ completion: @escaping (Swift.Result<Void, Error>) -> Void) {
        let context = ContextManager.shared.newDerivedContext()
        context.perform {
            do {
                try persistCategoriesToCoreData(layouts.categories, context: context)
                try persistLayoutsToCoreData(layouts.layouts, context: context)
            } catch {
                completion(.failure(error))
                return
            }
            ContextManager.shared.save(context)
            completion(.success(()))
        }
    }

    private static func persistCategoriesToCoreData(_ categories: [GutenbergLayoutCategory], context: NSManagedObjectContext) throws {
        let allCategories = context.allObjects(ofType: PageTemplateCategory.self)
        var categoriesToDelete = Set(allCategories)

        categories.forEach { (category) in

            let request: NSFetchRequest<PageTemplateCategory> = PageTemplateCategory.fetchRequest()
            request.predicate = NSPredicate(format: "\(#keyPath(PageTemplateCategory.slug)) = %@", category.slug)

            if let localCategory = try? context.fetch(request).first {
                categoriesToDelete.remove(localCategory)
                localCategory.update(with: category)
            } else {
                let _ = PageTemplateCategory(context: context, category: category)
            }
        }

        categoriesToDelete.forEach ({ context.delete($0) })
    }

    private static func persistLayoutsToCoreData(_ layouts: [GutenbergLayout], context: NSManagedObjectContext) throws {
        let allLayouts = context.allObjects(ofType: PageTemplateLayout.self)
        var layoutsToDelete = Set(allLayouts)

        for layout in layouts {
            let request: NSFetchRequest<PageTemplateLayout> = PageTemplateLayout.fetchRequest()
            request.predicate = NSPredicate(format: "\(#keyPath(PageTemplateLayout.slug)) = %@", layout.slug)

            if let localLayout = try? context.fetch(request).first {
                layoutsToDelete.remove(localLayout)
                localLayout.update(with: layout)
                try associate(layout: localLayout, toCategories: layout.categories, context: context)
            } else {
                let localLayout = PageTemplateLayout(context: context, layout: layout)
                try associate(layout: localLayout, toCategories: layout.categories, context: context)
            }
        }

        layoutsToDelete.forEach ({ context.delete($0) })
    }

    private static func associate(layout: PageTemplateLayout, toCategories categories: [GutenbergLayoutCategory], context: NSManagedObjectContext) throws {
        let categoryList = categories.map({ $0.slug })
        let request: NSFetchRequest<PageTemplateCategory> = PageTemplateCategory.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(PageTemplateCategory.slug)) IN %@", categoryList)
        let fetchedCategories = try context.fetch(request)
        layout.categories = Set(fetchedCategories)
    }
}
