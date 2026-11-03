import '../models.dart';
import 'local_catalog_service.dart';

class CatalogService {
  Future<Map<int, UnitCatalogEntry>> load({bool forceReload = false}) {
    return LocalCatalogService.load(force: forceReload);
  }
}