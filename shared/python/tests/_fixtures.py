"""Small historical-format fixtures; production creates indexed projects."""
import json
from _workbench_store import ProjectStore, canonical


def use_legacy_storage(project):
    """Retain format1 export/recovery coverage without changing new defaults."""
    store = ProjectStore(str(project))
    document = store.read()
    value = json.loads(canonical(document))
    value.pop('storageFormat', None)
    if hasattr(document, 'view'): document.view.close()
    connection = store.connection()
    try:
        with connection:
            connection.execute('UPDATE state SET document=? WHERE id=1', (canonical(value),))
    finally: connection.close()
