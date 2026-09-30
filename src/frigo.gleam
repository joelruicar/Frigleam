import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import varasto

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", 0)
  Nil
}

pub type Item {
  Item(name: String, amount: Int, checked: Bool, category: String)
}

pub type Model {
  Model(
    items_storage: varasto.TypedStorage(List(Item)),
    items: List(Item),
    scanning: Bool,
    editing: Option(String),
    confirm_delete_list: Bool,
    draft_name: String,
    draft_amount: String,
    draft_category: String,
    collapsed_sections: List(String),
    room_id: String,
    connected: Bool,
    show_share_modal: Bool,
    show_switch_modal: Bool,
    switch_room_input: String,
    copied_toast: Bool,
  )
}

pub type Message {
  Noop

  // Items & Editing
  UserAddedItem(List(#(String, String)))
  UserDeletedItem(String)
  UserToggledItem(String)
  UserAskedToDeleteList
  UserCancelledDeleteList
  UserConfirmedDeleteList
  UserClickedItem(name: String, amount: Int, category: String)
  UserChangedDraftName(String)
  UserChangedDraftAmount(String)
  UserChangedDraftCategory(String)
  UserConfirmedEdit

  // Sections
  UserToggledSection(category: String)

  // OCR
  UserSelectedImage(dynamic.Dynamic)
  UserScannedText(String)

  // Real-time synchronization
  RemoteItemsReceived(dynamic.Dynamic)
  ConnectionStatusChanged(Bool)

  // Sharing & Room switching
  UserOpenedShareModal
  UserClosedShareModal
  UserClickedNativeShare
  UserClickedCopyLink
  UserOpenedSwitchModal
  UserClosedSwitchModal
  UserChangedSwitchInput(String)
  UserConfirmedSwitchRoom
  UserGenerateRandomRoom
}

// =============================================================================
// FFI External Bindings
// =============================================================================

@external(javascript, "./frigo_ffi.mjs", "get_file_from_input")
fn get_file_from_input(event: dynamic.Dynamic) -> dynamic.Dynamic

@external(javascript, "./frigo_ffi.mjs", "is_null_file")
fn is_null_file(file: dynamic.Dynamic) -> Bool

@external(javascript, "./frigo_ffi.mjs", "scan_image")
fn do_scan_image(file: dynamic.Dynamic, dispatch: fn(String) -> Nil) -> Nil

@external(javascript, "./frigo_ffi.mjs", "get_active_room_id")
fn get_active_room_id() -> String

@external(javascript, "./frigo_ffi.mjs", "set_active_room_id")
fn set_active_room_id(room_id: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "sanitize_room_id")
fn sanitize_room_id(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "random_room_id")
fn random_room_id() -> String

@external(javascript, "./frigo_ffi.mjs", "start_sync")
fn do_start_sync(
  room_id: String,
  on_sync: fn(dynamic.Dynamic) -> Nil,
  on_status: fn(Bool) -> Nil,
) -> Nil

@external(javascript, "./frigo_ffi.mjs", "broadcast_items_json")
fn broadcast_items_json(json_string: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "share_room_link")
fn share_room_link(room_id: String) -> Bool

@external(javascript, "./frigo_ffi.mjs", "copy_to_clipboard")
fn copy_to_clipboard(text: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "get_share_link")
fn get_share_link(room_id: String) -> String

@external(javascript, "./frigo_ffi.mjs", "render_qr_code")
fn render_qr_code(element_id: String, text: String) -> Nil

@external(javascript, "./frigo_ffi.mjs", "enable_swipe_to_delete")
fn enable_swipe_to_delete(on_swipe: fn(String) -> Nil) -> Nil

// =============================================================================
// Categories & Helpers
// =============================================================================

pub const standard_categories = [
  "🌱 Veggie",
  "🥬 Frutas y verduras",
  "🥩 Carne y pescado",
  "🥛 Lácteos y huevos",
  "🥖 Panadería",
  "🥫 Despensa",
  "🍫 Dulces y snacks",
  "🥤 Bebidas",
  "🧊 Congelados",
  "🧼 Limpieza",
  "🧴 Cuidado personal",
  "👶 Bebé",
  "🐾 Mascotas",
  "💊 Farmacia y salud",
  "🏠 Hogar y bazar",
  "📦 Otros",
]

pub fn infer_category(name: String) -> String {
  let lower = string.lowercase(name)

  let rules = [
    #(
      "🌱 Veggie",
      [
        // Proteínas vegetales
        "tofu", "tofu ahumado", "tofu firme", "tofu sedoso", "tempeh", "seitan",
        "soja texturizada", "proteina texturizada", "proteína texturizada",
        "proteina de soja", "proteína de soja", "edamame", "jackfruit", "yaca",
        "jaca", "heura", "quorn", "garden gourmet", "beyond meat", "vegetalia",
        "taifun", "soja", "soja texturizada",

        // Elaborados tipo falafel
        "falafel", "hummus", "humus", "hummus de remolacha", "baba ganoush",
        "tahini", "tahin", "pasta de sesamo", "pasta de sésamo",
        "crema de sesamo", "crema de sésamo", "harina de garbanzo",
        "masa de garbanzo", "aquafaba",

        // Sustitutos de carne y pescado
        "hamburguesa vegetal", "hamburguesa vegana", "hamburguesa de soja",
        "hamburguesa de lentejas", "hamburguesa de garbanzos",
        "hamburguesa de quinoa", "burger vegetal", "burger vegana",
        "salchicha vegetal", "salchichas vegetales", "salchicha vegana",
        "salchichas veganas", "nuggets vegetales", "nuggets veganos",
        "albondigas vegetales", "albóndigas vegetales", "albondigas veganas",
        "albóndigas veganas", "carne vegetal", "carne vegana", "pollo vegetal",
        "pollo vegano", "kebab vegetal", "shawarma vegetal", "bacon vegetal",
        "beicon vegetal", "jamon vegano", "jamón vegano", "fiambre vegetal",
        "mortadela vegetal", "chorizo vegano", "chorizo vegetal",
        "atun vegano", "atún vegano", "gambas veganas", "gyozas vegetales",
        "croquetas veganas", "rebozado vegano", "lonchas veganas",
        "lonchas vegetales", "pate vegetal", "paté vegetal", "pate vegano",
        "paté vegano", "pulled vegetal",

        // Sustitutos de lácteos y huevo
        "queso vegano", "queso vegetal", "queso de anacardo", "yogur vegetal",
        "yogur vegano", "yogur de soja", "yogur de coco", "postre de soja",
        "postre vegetal", "nata vegetal", "mantequilla vegana",
        "mayonesa vegana", "huevo vegano", "just egg", "helado vegano",

        // Ingredientes típicos de cocina vegetariana
        "levadura nutricional", "copos de levadura", "miso", "nori", "alga nori",
        "algas", "wakame", "kombu", "spirulina", "espirulina",

        // Etiquetas generales
        "vegano", "vegana", "veganos", "veganas", "veggie", "vegetariano",
        "vegetariana", "plant based", "plant-based",
      ],
    ),
    #(
      "🧊 Congelados",
      [
        "helado", "helados", "pizza", "pizzas", "congelad", "hielo", "nugget",
        "nuggets", "croqueta", "croquetas", "guisantes congelados", "sorbete",
        "tarta helada", "empanadilla", "empanadillas", "lasaña", "lasana",
        "San Jacobo", "san jacobo", "varitas", "verdura congelada",
        "patatas congeladas", "patatas fritas congeladas", "rebozados",
        "gyozas", "wok congelado", "masa de pizza", "hojaldre", "calamares",
        "anillas", "palitos de merluza", "pescado congelado", "polo", "polos",
        "cornetto", "tarrina",
      ],
    ),
    #(
      "🧴 Cuidado personal",
      [
        "champu", "champú", "gel", "pasta de dientes", "dentifrico", "dentífrico",
        "desodorante", "jabon", "jabón", "crema", "toallita", "toallitas",
        "cuchilla", "acondicionador", "colutorio", "hilo dental", "cepillo",
        "cepillo de dientes", "maquinilla", "espuma de afeitar", "afeitar",
        "after shave", "mascarilla", "crema solar", "protector solar",
        "bastoncillos", "algodon", "algodón", "discos desmaquillantes",
        "desmaquillante", "tampones", "tampon", "compresas", "compresa",
        "salvaslip", "copa menstrual", "perfume", "colonia", "laca", "gomina",
        "tinte", "esmalte", "quitaesmalte", "pañuelos", "panuelos", "kleenex",
        "gel de ducha", "gel de baño", "hidratante", "labial", "cacao labios",
        "depilatoria", "cera depilatoria", "preservativo", "preservativos",
      ],
    ),
    #(
      "🧼 Limpieza",
      [
        "detergente", "suavizante", "lavavajillas", "fairy", "lejia", "lejía",
        "papel higienico", "papel higiénico", "servilleta", "servilletas",
        "bolsa basura", "bolsas basura", "bolsas de basura", "estropajo",
        "bayeta", "limpiacristal", "limpiacristales", "fregasuelo", "fregona",
        "scrop", "papel cocina", "amoniaco", "desengrasante", "antical",
        "limpiahogar", "multiusos", "wc", "pastillas wc", "ambientador",
        "insecticida", "cubo", "escoba", "recogedor", "guantes", "friegaplatos",
        "quitamanchas", "vanish", "ariel", "skip", "perlas", "capsulas",
        "cápsulas", "sal lavavajillas", "abrillantador", "limpiador",
        "desinfectante", "rollo de cocina", "papel de aluminio", "aluminio",
        "film", "papel film", "papel albal", "bolsas de congelar",
        "papel de horno", "papel vegetal", "fregaplatos", "trapo", "mopa",
      ],
    ),
    #(
      "🐾 Mascotas",
      [
        "pienso", "arena gatos", "arena para gatos", "arena de gato", "comida perro",
        "comida gato", "comida para perros", "comida para gatos", "snack perro",
        "snack gato", "galletas perro", "collar", "correa", "antiparasitario",
        "pipeta", "whiskas", "purina", "pedigree", "friskies", "latas gato",
        "latas perro", "hamster", "pajaros", "pájaros", "alpiste", "piedras gato",
      ],
    ),
    #(
      "👶 Bebé",
      [
        "pañal", "pañales", "panal", "panales", "toallitas bebe", "toallitas bebé",
        "leche infantil", "leche de continuación", "papilla", "papillas",
        "potito", "potitos", "biberon", "biberón", "chupete", "crema pañal",
        "colonia bebe", "colonia bebé", "cereales bebe", "cereales bebé",
        "tarrito", "tarritos",
      ],
    ),
    #(
      "💊 Farmacia y salud",
      [
        "ibuprofeno", "paracetamol", "aspirina", "dalsy", "tiritas", "tirita",
        "gasas", "gasa", "esparadrapo", "alcohol", "agua oxigenada", "betadine",
        "termometro", "termómetro", "vitamina", "vitaminas", "magnesio",
        "omega 3", "suplemento", "jarabe", "pastillas garganta", "strepsils",
        "antihistaminico", "antihistamínico", "colirio", "suero", "mascarillas",
        "test covid", "test de embarazo", "pomada", "voltaren", "melatonina",
        "probioticos", "probióticos", "proteina", "proteína", "creatina",
      ],
    ),
    #(
      "🥫 Despensa",
      [
        "arroz", "pasta", "macarron", "macarrón", "macarrones", "espagueti",
        "espaguetis", "fideo", "fideos", "aceite", "vinagre", "sal", "azucar",
        "azúcar", "cafe", "café", "lenteja", "lentejas", "garbanzo", "garbanzos",
        "alubia", "alubias", "tomate frito", "tomate triturado", "conserva",
        "conservas", "cereal", "cereales", "especias", "pimienta", "oregano",
        "orégano", "mayonesa", "ketchup", "mostaza", "mermelada", "miel",
        "atun lata", "atún lata", "atun en lata", "atún en lata", "caldo",
        "tallarines", "lasaña", "lasana", "tortellini", "ravioli", "noodles",
        "cuscus", "cuscús", "quinoa", "bulgur", "polenta", "sémola", "semola",
        "avena", "copos de avena", "muesli", "granola", "cacao", "colacao",
        "nesquik", "cola cao", "chocolate en polvo", "nutella", "crema de cacahuete",
        "mantequilla de cacahuete", "sirope", "sacarina", "edulcorante",
        "stevia", "levadura", "bicarbonato", "maicena", "gelatina", "pure",
        "puré", "sopa", "sopa de sobre", "gazpacho", "salsa", "salsa de tomate",
        "salsa de soja", "soja", "pesto", "sriracha", "tabasco", "alioli",
        "tomate natural", "pimientos del piquillo", "piquillo", "aceitunas",
        "aceituna", "pepinillos", "encurtidos", "alcaparras", "sardinas",
        "mejillones", "berberechos", "anchoas", "caballa en lata", "palmitos",
        "maiz", "maíz", "maiz dulce", "judias", "judías", "garbanzos cocidos",
        "lentejas cocidas", "legumbre", "legumbres", "fabada", "cocido",
        "aceite de oliva", "aceite de girasol", "aceite girasol", "pimenton",
        "pimentón", "comino", "curry", "canela", "nuez moscada", "laurel",
        "perejil seco", "tomillo", "romero", "ajo en polvo", "cebolla en polvo",
        "azafran", "azafrán", "colorante", "sal gorda", "sal fina", "pastillas de caldo",
        "avecrem", "gallina blanca", "knorr", "bechamel", "tomate en polvo",
        "arroz bomba", "arroz integral", "paella", "sofrito", "galletas maria",
        "pan rallado", "rebozador", "tortitas de arroz", "frutos secos",
        "almendra", "almendras", "nueces", "nuez", "cacahuete", "cacahuetes",
        "pistacho", "pistachos", "anacardo", "anacardos", "avellana", "avellanas",
        "pipas", "pasas", "datiles", "dátiles", "ciruelas pasas", "orejones",
      ],
    ),
    #(
      "🥤 Bebidas",
      [
        "agua", "cerveza", "cervezas", "vino", "zumo", "zumos", "refresco",
        "refrescos", "coca", "pepsi", "fanta", "te", "té", "infusion",
        "infusión", "tonica", "tónica", "gaseosa", "cola", "sprite", "7up",
        "aquarius", "nestea", "red bull", "monster", "bebida energetica",
        "bebida energética", "isotonica", "isotónica", "gatorade", "powerade",
        "tinto", "blanco", "rosado", "cava", "champan", "champán", "sidra",
        "vermut", "vermú", "ginebra", "ron", "vodka", "whisky", "licor",
        "tequila", "brandy", "coñac", "conac", "cerveza sin alcohol", "sangria",
        "sangría", "tinto de verano", "limonada", "horchata", "batido", "bebida vegetal",
        "leche de almendras", "leche de avena", "leche de soja", "leche de coco",
        "agua con gas", "agua mineral", "soda", "kombucha", "mosto", "cafe frio",
        "café frío", "capsulas de cafe", "cápsulas de café", "nespresso",
        "dolce gusto", "manzanilla", "poleo", "tila", "rooibos", "cacao soluble",
        "mahou", "estrella", "damm", "cruzcampo", "heineken", "san miguel",
      ],
    ),
    #(
      "🍫 Dulces y snacks",
      [
        "chocolate", "chocolatina", "chocolatinas", "bombon", "bombón", "bombones",
        "caramelo", "caramelos", "chicle", "chicles", "gominola", "gominolas",
        "chucheria", "chucherías", "chuches", "patatas fritas", "patatas chips",
        "chips", "ganchitos", "doritos", "pringles", "palomitas", "nachos",
        "tortilla chips", "snack", "snacks", "barrita", "barritas", "galleta",
        "galletas", "oreo", "principe", "príncipe", "digestive", "turron",
        "turrón", "polvorones", "mazapan", "mazapán", "membrillo", "natillas",
        "gelatina postre", "postre", "postres", "tarta", "pastel", "donut",
        "donuts", "napolitana", "palmera", "ensaimada", "cookies", "brownie",
        "kinder", "bueno", "snickers", "twix", "kitkat", "m&m", "lacasitos",
        "regaliz", "piruleta", "pirulis", "cacahuetes fritos", "tostadas dulces",
      ],
    ),
    #(
      "🥛 Lácteos y huevos",
      [
        "leche", "queso", "yogur", "yogures", "yogurt", "mantequilla", "nata",
        "huevo", "huevos", "mozzarella", "parmesano", "requeson", "requesón",
        "cuajada", "lacteo", "lácteo", "lacteos", "lácteos", "cheddar", "brie",
        "gorgonzola", "flan", "kefir", "kéfir", "skyr", "margarina", "queso fresco",
        "queso rallado", "queso crema", "philadelphia", "burgos", "manchego",
        "cabra", "feta", "halloumi", "emmental", "gouda", "edam", "provolone",
        "ricotta", "mascarpone", "nata para cocinar", "nata montada",
        "leche condensada", "leche evaporada", "leche en polvo", "actimel",
        "danone", "petit suisse", "batido lacteo", "batido lácteo", "arroz con leche",
        "cuajada", "queso en lonchas", "lonchas de queso", "sobrasada",
      ],
    ),
    #(
      "🥩 Carne y pescado",
      [
        "pollo", "ternera", "cerdo", "carne", "pavo", "jamon", "jamón", "salchicha",
        "salchichas", "lomo", "bacon", "beicon", "chuleta", "hamburguesa",
        "pescado", "salmon", "salmón", "atun", "atún", "merluza", "gamba",
        "gambas", "langostino", "langostinos", "bacalao", "dorada", "lubina",
        "filete", "costillas", "pechuga", "muslo", "muslos", "alitas", "contramuslo",
        "cordero", "conejo", "pato", "codorniz", "chorizo", "salchichon",
        "salchichón", "fuet", "morcilla", "butifarra", "longaniza", "panceta",
        "tocino", "chopped", "mortadela", "york", "jamón york", "jamon york",
        "jamón serrano", "jamon serrano", "paleta", "lacon", "lacón", "embutido",
        "embutidos", "fiambre", "carne picada", "picada", "albondigas",
        "albóndigas", "solomillo", "entrecot", "secreto", "presa", "magret",
        "rabo", "morcillo", "osobuco", "cinta de lomo", "sepia", "calamar",
        "pulpo", "mejillon", "mejillón", "almeja", "almejas", "vieira", "rape",
        "rodaballo", "lenguado", "sardina", "sardinas", "boqueron", "boquerón",
        "boquerones", "caballa", "trucha", "pez espada", "emperador", "bonito",
        "gallo", "sepia", "chipiron", "chipirón", "chipirones", "surimi",
        "gulas", "marisco", "mariscos", "cigala", "cigalas", "nécora", "necora",
        "centollo", "bogavante", "langosta", "tartar", "salmón ahumado",
        "ahumado", "ahumados", "lomo embuchado", "cecina", "hígado", "higado",
      ],
    ),
    #(
      "🥖 Panadería",
      [
        "pan", "tostada", "tostadas", "croissant", "croissants", "bollo",
        "bollos", "magdalena", "magdalenas", "baguette", "harina", "bizcocho",
        "barra", "picos", "pan de molde", "pan integral", "pan rallado",
        "panecillo", "panecillos", "bocadillo", "pan de hamburguesa",
        "pan de perrito", "pan bimbo", "bimbo", "pan tostado", "biscotes",
        "regañá", "regana", "colines", "rosquilletas", "chapata", "ciabatta",
        "pita", "tortilla de trigo", "tortillas de trigo", "wrap", "wraps",
        "tortilla mexicana", "masa", "masa de hojaldre", "masa quebrada",
        "empanada", "empanadas", "hogaza", "pan de centeno", "pan sin gluten",
        "coca de", "roscón", "roscon", "torrijas", "pan de pasas",
      ],
    ),
    #(
      "🥬 Frutas y verduras",
      [
        "manzana", "platano", "plátano", "naranja", "pera", "limon", "limón",
        "aguacate", "tomate", "lechuga", "cebolla", "patata", "zanahoria",
        "calabacin", "calabacín", "pimiento", "ajo", "fresa", "uva", "melon",
        "melón", "sandia", "sandía", "espinaca", "brocoli", "brócoli", "champiñon",
        "champiñón", "seta", "kiwi", "mandarina", "pepino", "puerro", "verdura",
        "fruta", "cereza", "calabaza", "fresas", "tomates", "patatas", "berenjena",
        "coliflor", "col", "repollo", "lombarda", "acelga", "acelgas", "judia verde",
        "judía verde", "judias verdes", "judías verdes", "guisantes", "habas",
        "esparrago", "espárrago", "esparragos", "espárragos", "alcachofa",
        "alcachofas", "apio", "remolacha", "rabano", "rábano", "nabo", "boniato",
        "batata", "chirivia", "chirivía", "endivia", "endivias", "escarola",
        "rucula", "rúcula", "canonigos", "canónigos", "brotes", "ensalada",
        "bolsa de ensalada", "cebolleta", "cebollino", "chalota", "chalotas",
        "perejil", "cilantro", "albahaca", "menta", "hierbabuena", "eneldo",
        "jengibre", "guindilla", "chile", "jalapeño", "jalapeno", "pimiento rojo",
        "pimiento verde", "pimientos", "tomate cherry", "tomate pera",
        "tomate rama", "tomate de ensalada", "limones", "limas", "lima", "pomelo",
        "clementina", "clementinas", "mandarinas", "naranjas", "manzanas",
        "peras", "platanos", "plátanos", "banana", "bananas", "melocoton",
        "melocotón", "nectarina", "albaricoque", "ciruela", "ciruelas", "cerezas",
        "higo", "higos", "granada", "caqui", "chirimoya", "mango", "papaya",
        "piña", "pina", "coco", "maracuya", "maracuyá", "lichi", "frambuesa",
        "frambuesas", "arandanos", "arándanos", "mora", "moras", "grosella",
        "melones", "sandias", "sandías", "uvas", "membrillo fresco", "dátil fresco",
        "champiñones", "setas", "shiitake", "portobello", "boletus", "trufa",
        "maiz fresco", "maíz fresco", "mazorca", "rabanitos", "zanahorias",
        "cebollas", "ajos", "calabacines", "berenjenas", "pepinos", "puerros",
        "aguacates", "hortaliza", "hortalizas", "fruta de temporada", "frutas",
        "verduras", "macedonia", "sofrito fresco", "guacamole", "hummus",
      ],
    ),
    #(
      "🏠 Hogar y bazar",
      [
        "pila", "pilas", "bombilla", "bombillas", "vela", "velas", "cerillas",
        "mechero", "encendedor", "pegamento", "cinta adhesiva", "celo",
        "tijeras", "boligrafo", "bolígrafo", "cuaderno", "folios", "sobre",
        "sobres", "percha", "perchas", "pinzas", "tendedero", "plancha",
        "sarten", "sartén", "olla", "cazuela", "cubiertos", "vaso", "vasos",
        "plato", "platos", "taza", "tazas", "tupper", "tuppers", "fiambrera",
        "botella reutilizable", "termo", "sabana", "sábana", "toalla", "toallas",
        "manta", "almohada", "cortina", "alargador", "regleta", "enchufe",
        "cable", "cargador", "usb", "bateria", "batería", "destornillador",
        "martillo", "clavos", "tornillos", "taladro", "brocha", "pintura",
        "maceta", "tierra", "abono", "semillas", "flores", "planta", "plantas",
        "calcetines", "calzoncillos", "camiseta", "ropa", "zapatillas", "bolsa",
      ],
    ),
  ]

  let words =
    lower
    |> string.split(" ")
    |> list.map(string.trim)

  rules
  |> list.find_map(fn(rule) {
    let #(category, keywords) = rule
    case contains_any(words, lower, keywords) {
      True -> Ok(category)
      False -> Error(Nil)
    }
  })
  |> result.unwrap("📦 Otros")
}

fn contains_any(
  words: List(String),
  full_text: String,
  keywords: List(String),
) -> Bool {
  list.any(keywords, fn(kw) {
    let kw_lower = string.lowercase(kw)
    case string.contains(kw_lower, " ") {
      True -> string.contains(full_text, kw_lower)
      False ->
        case string.length(kw_lower) <= 4 {
          True ->
            list.any(words, fn(w) {
              w == kw_lower || w == kw_lower <> "s" || w == kw_lower <> "es"
            })
          False -> string.contains(full_text, kw_lower)
        }
    }
  })
}

/// Unchecked first, then alphabetical.
pub fn sort_items(items: List(Item)) -> List(Item) {
  list.sort(items, by: fn(a, b) {
    case a.checked, b.checked {
      False, True -> order.Lt
      True, False -> order.Gt
      _, _ -> string.compare(a.name, b.name)
    }
  })
}

/// Adds `amount` to an existing item (unchecking it) or prepends a new one with its category.
pub fn merge_item(
  items: List(Item),
  name: String,
  amount: Int,
  category: String,
) -> List(Item) {
  case list.any(items, fn(item) { item.name == name }) {
    True ->
      list.map(items, fn(item) {
        case item.name == name {
          True -> Item(..item, amount: item.amount + amount, checked: False)
          False -> item
        }
      })
    False -> [Item(name, amount, False, category), ..items]
  }
}

pub fn parse_scanned_line(line: String) -> #(String, Int) {
  let words =
    line
    |> string.split(" ")
    |> list.filter(fn(w) { w != "" })

  let amount =
    words
    |> list.find_map(int.parse)
    |> result.unwrap(1)

  let name_words = list.filter(words, fn(w) { result.is_error(int.parse(w)) })

  case name_words {
    [] -> #("", amount)
    _ -> #(string.capitalise(string.join(name_words, " ")), amount)
  }
}

fn load_room_items(
  storage: varasto.TypedStorage(List(Item)),
  room_id: String,
) -> List(Item) {
  varasto.get(storage, "items_" <> room_id)
  |> result.unwrap([])
}

fn persist_and_broadcast_effect(
  storage: varasto.TypedStorage(List(Item)),
  room_id: String,
  items: List(Item),
) -> effect.Effect(Message) {
  effect.from(fn(_) {
    let _ = varasto.set(storage, "items_" <> room_id, items)
    broadcast_items_json(json.to_string(writer(items)))
  })
}

/// Sort, store in the model, persist locally and broadcast.
fn save(model: Model, items: List(Item)) -> #(Model, effect.Effect(Message)) {
  let sorted = sort_items(items)
  #(
    Model(..model, items: sorted),
    persist_and_broadcast_effect(model.items_storage, model.room_id, sorted),
  )
}

fn start_sync_effect(room_id: String) -> effect.Effect(Message) {
  effect.from(fn(dispatch) {
    do_start_sync(
      room_id,
      fn(raw) { dispatch(RemoteItemsReceived(raw)) },
      fn(status) { dispatch(ConnectionStatusChanged(status)) },
    )
  })
}

// =============================================================================
// Update Loop
// =============================================================================

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case message {
    Noop -> #(model, effect.none())

    // --- Items ---------------------------------------------------------------
    UserAddedItem(form_item) -> {
      let name =
        list.key_find(form_item, "input_form")
        |> result.unwrap("")
        |> string.trim
        |> string.capitalise

      let count =
        list.key_find(form_item, "input_count")
        |> result.try(int.parse)
        |> result.unwrap(1)
        |> int.max(1)

      case name {
        "" -> #(model, effect.none())
        _ -> {
          let category = infer_category(name)
          save(model, merge_item(model.items, name, count, category))
        }
      }
    }

    UserToggledItem(name) ->
      save(
        model,
        list.map(model.items, fn(item) {
          case item.name == name {
            True -> Item(..item, checked: !item.checked)
            False -> item
          }
        }),
      )

    UserDeletedItem(name) ->
      save(model, list.filter(model.items, fn(item) { item.name != name }))

    // --- Clear list ----------------------------------------------------------
    UserAskedToDeleteList -> #(
      Model(..model, confirm_delete_list: True),
      effect.none(),
    )

    UserCancelledDeleteList -> #(
      Model(..model, confirm_delete_list: False),
      effect.none(),
    )

    UserConfirmedDeleteList -> {
      let #(m, eff) = save(model, [])
      #(Model(..m, confirm_delete_list: False), eff)
    }

    // --- Inline editing ------------------------------------------------------
    UserClickedItem(name, amount, category) -> #(
      Model(
        ..model,
        editing: Some(name),
        draft_name: name,
        draft_amount: int.to_string(amount),
        draft_category: category,
      ),
      effect.none(),
    )

    UserChangedDraftName(value) -> #(
      Model(..model, draft_name: value),
      effect.none(),
    )

    UserChangedDraftAmount(value) -> #(
      Model(..model, draft_amount: value),
      effect.none(),
    )

    UserChangedDraftCategory(value) -> #(
      Model(..model, draft_category: value),
      effect.none(),
    )

    UserConfirmedEdit ->
      case model.editing {
        None -> #(model, effect.none())
        Some(original_name) -> {
          let new_name = string.capitalise(string.trim(model.draft_name))
          let original =
            list.find(model.items, fn(item) { item.name == original_name })

          case new_name, int.parse(model.draft_amount), original {
            "", _, _ | _, Error(_), _ | _, _, Error(_) -> #(
              Model(..model, editing: None),
              effect.none(),
            )
            _, Ok(new_amount), Ok(original_item) -> {
              let others =
                list.filter(model.items, fn(item) { item.name != original_name })

              let updated = case
                list.find(others, fn(item) { item.name == new_name })
              {
                Ok(existing) -> [
                  Item(
                    new_name,
                    existing.amount + new_amount,
                    False,
                    model.draft_category,
                  ),
                  ..list.filter(others, fn(item) { item.name != new_name })
                ]
                Error(_) -> [
                  Item(
                    name: new_name,
                    amount: new_amount,
                    checked: original_item.checked,
                    category: model.draft_category,
                  ),
                  ..others
                ]
              }

              let #(m, eff) = save(model, updated)
              #(Model(..m, editing: None), eff)
            }
          }
        }
      }

    // --- Sections ------------------------------------------------------------
    UserToggledSection(cat) -> {
      let is_collapsed = list.contains(model.collapsed_sections, cat)
      let new_collapsed = case is_collapsed {
        True -> list.filter(model.collapsed_sections, fn(c) { c != cat })
        False -> [cat, ..model.collapsed_sections]
      }
      #(Model(..model, collapsed_sections: new_collapsed), effect.none())
    }

    // --- OCR -----------------------------------------------------------------
    UserSelectedImage(event) -> {
      let file = get_file_from_input(event)
      case is_null_file(file) {
        True -> #(model, effect.none())
        False -> #(
          Model(..model, scanning: True),
          effect.from(fn(dispatch) {
            do_scan_image(file, fn(text) { dispatch(UserScannedText(text)) })
          }),
        )
      }
    }

    UserScannedText(text) -> {
      let updated =
        text
        |> string.split("\n")
        |> list.map(string.trim)
        |> list.filter(fn(l) { l != "" })
        |> list.map(parse_scanned_line)
        |> list.filter(fn(pair) { pair.0 != "" })
        |> list.fold(model.items, fn(acc, pair) {
          let category = infer_category(pair.0)
          merge_item(acc, pair.0, pair.1, category)
        })

      let #(m, eff) = save(model, updated)
      #(Model(..m, scanning: False), eff)
    }

    // --- Real-time sync ------------------------------------------------------
    RemoteItemsReceived(raw) ->
      case decode.run(raw, reader()) {
        Ok(remote_items) -> {
          let sorted = sort_items(remote_items)
          #(
            Model(..model, items: sorted),
            effect.from(fn(_) {
              let _ =
                varasto.set(
                  model.items_storage,
                  "items_" <> model.room_id,
                  sorted,
                )
              Nil
            }),
          )
        }
        Error(_) -> #(model, effect.none())
      }

    ConnectionStatusChanged(is_connected) -> #(
      Model(..model, connected: is_connected),
      effect.none(),
    )

    // --- Share modal ---------------------------------------------------------
    UserOpenedShareModal -> {
      let link = get_share_link(model.room_id)
      #(
        Model(..model, show_share_modal: True),
        effect.from(fn(_) { render_qr_code("share-qr-code", link) }),
      )
    }

    UserClosedShareModal -> #(
      Model(..model, show_share_modal: False, copied_toast: False),
      effect.none(),
    )

    UserClickedNativeShare -> #(
      model,
      effect.from(fn(_) {
        let _ = share_room_link(model.room_id)
        Nil
      }),
    )

    UserClickedCopyLink -> #(
      Model(..model, copied_toast: True),
      effect.from(fn(_) { copy_to_clipboard(get_share_link(model.room_id)) }),
    )

    // --- Room switching ------------------------------------------------------
    UserOpenedSwitchModal -> #(
      Model(..model, show_switch_modal: True, switch_room_input: model.room_id),
      effect.none(),
    )

    UserClosedSwitchModal -> #(
      Model(..model, show_switch_modal: False),
      effect.none(),
    )

    UserChangedSwitchInput(value) -> #(
      Model(..model, switch_room_input: value),
      effect.none(),
    )

    UserGenerateRandomRoom -> #(
      Model(..model, switch_room_input: random_room_id()),
      effect.none(),
    )

    UserConfirmedSwitchRoom ->
      case sanitize_room_id(model.switch_room_input) {
        "" -> #(model, effect.none())
        room -> #(
          Model(
            ..model,
            room_id: room,
            items: load_room_items(model.items_storage, room),
            show_switch_modal: False,
            connected: False,
          ),
          effect.batch([
            effect.from(fn(_) { set_active_room_id(room) }),
            start_sync_effect(room),
          ]),
        )
      }
  }
}

// =============================================================================
// View
// =============================================================================

fn modal(
  on_close: Message,
  title: String,
  children: List(Element(Message)),
) -> Element(Message) {
  html.div([attribute.class("modal-backdrop"), event.on_click(on_close)], [
    html.div(
      [
        attribute.class("modal"),
        event.stop_propagation(event.on_click(Noop)),
      ],
      [
        html.h3([attribute.class("modal-title")], [element.text(title)]),
        ..children
      ],
    ),
  ])
}

fn text_button(
  class: String,
  on_click: Message,
  label: String,
) -> Element(Message) {
  html.button([attribute.class(class), event.on_click(on_click)], [
    element.text(label),
  ])
}

fn view_item(model: Model, item: Item) -> Element(Message) {
  let checkbox =
    html.input([
      attribute.type_("checkbox"),
      attribute.checked(item.checked),
      event.on_click(UserToggledItem(item.name)),
    ])

  case model.editing {
    Some(name) if name == item.name ->
      html.li([attribute.class("grocery-item editing")], [
        checkbox,
        html.div([attribute.class("edit-fields-column")], [
          html.div([attribute.class("edit-name-amount-row")], [
            html.input([
              attribute.class("edit-name"),
              attribute.value(model.draft_name),
              event.on_input(UserChangedDraftName),
            ]),
            html.input([
              attribute.class("edit-amount"),
              attribute.type_("number"),
              attribute.min("1"),
              attribute.value(model.draft_amount),
              event.on_input(UserChangedDraftAmount),
            ]),
            html.button(
              [
                attribute.class("confirm-btn"),
                event.on_click(UserConfirmedEdit),
                attribute.attribute("aria-label", "Guardar cambios"),
              ],
              [element.text("✓")],
            ),
          ]),
          html.select(
            [
              attribute.class("edit-category-select"),
              event.on_input(UserChangedDraftCategory),
            ],
            list.map(standard_categories, fn(cat) {
              html.option(
                [
                  attribute.value(cat),
                  attribute.selected(model.draft_category == cat),
                ],
                cat,
              )
            }),
          ),
        ]),
      ])

    _ -> {
      let edit =
        event.on_click(UserClickedItem(item.name, item.amount, item.category))
      html.li(
        [
          attribute.class("grocery-item"),
          attribute.attribute("data-swipe-item", item.name),
        ],
        [
          checkbox,
          html.span(
            [
              attribute.classes([
                #("item-name", True),
                #("crossed", item.checked),
              ]),
              edit,
            ],
            [element.text(item.name)],
          ),
          html.span(
            [
              attribute.classes([
                #("item-amount", True),
                #("crossed", item.checked),
              ]),
              edit,
            ],
            [element.text(int.to_string(item.amount))],
          ),
          html.button(
            [
              attribute.class("delete-btn"),
              event.on_click(UserDeletedItem(item.name)),
              attribute.attribute("aria-label", "Borrar item"),
            ],
            [element.text("×")],
          ),
        ],
      )
    }
  }
}

fn view_share_modal(model: Model) -> Element(Message) {
  case model.show_share_modal {
    False -> element.none()
    True ->
      modal(UserClosedShareModal, "Compartir lista", [
        html.p([attribute.class("modal-desc")], [
          element.text(
            "Cualquiera con este enlace o código podrá ver y editar la lista en tiempo real:",
          ),
        ]),
        html.div([attribute.class("qr-wrapper")], [
          html.div([attribute.id("share-qr-code")], []),
          html.span([attribute.class("qr-hint")], [
            element.text("Escanea con la cámara de otro móvil"),
          ]),
        ]),
        html.div([attribute.class("share-input-row")], [
          html.input([
            attribute.class("input share-url-input"),
            attribute.value(get_share_link(model.room_id)),
            attribute.readonly(True),
          ]),
          text_button(
            "btn copy-btn",
            UserClickedCopyLink,
            case model.copied_toast {
              True -> "¡Copiado!"
              False -> "Copiar"
            },
          ),
        ]),
        html.div([attribute.class("modal-actions")], [
          text_button(
            "btn btn-primary full-width",
            UserClickedNativeShare,
            "📲 Enviar por WhatsApp / Compartir",
          ),
          text_button(
            "btn btn-secondary full-width",
            UserClosedShareModal,
            "Cerrar",
          ),
        ]),
      ])
  }
}

fn view_switch_modal(model: Model) -> Element(Message) {
  case model.show_switch_modal {
    False -> element.none()
    True ->
      modal(UserClosedSwitchModal, "Cambiar de lista", [
        html.p([attribute.class("modal-desc")], [
          element.text(
            "Introduce el nombre o código de la lista a la que quieres unirte:",
          ),
        ]),
        html.div([attribute.class("share-input-row")], [
          html.input([
            attribute.class("input"),
            attribute.placeholder("Ej: casa, finde, compra-familia"),
            attribute.value(model.switch_room_input),
            event.on_input(UserChangedSwitchInput),
          ]),
        ]),
        html.div([attribute.class("modal-actions")], [
          text_button(
            "btn btn-primary full-width",
            UserConfirmedSwitchRoom,
            "Unirme a esta lista",
          ),
          text_button(
            "btn btn-secondary full-width",
            UserGenerateRandomRoom,
            "🎲 Generar código aleatorio",
          ),
          text_button(
            "btn btn-secondary full-width",
            UserClosedSwitchModal,
            "Cancelar",
          ),
        ]),
      ])
  }
}

fn view_delete_modal(model: Model) -> Element(Message) {
  case model.confirm_delete_list {
    False -> element.none()
    True ->
      modal(UserCancelledDeleteList, "¿Vaciar toda la lista?", [
        html.div([attribute.class("modal-actions")], [
          text_button("btn btn-secondary", UserCancelledDeleteList, "Cancelar"),
          text_button("btn btn-danger", UserConfirmedDeleteList, "Vaciar"),
        ]),
      ])
  }
}

fn view_category_section(
  model: Model,
  category: String,
  items: List(Item),
) -> Element(Message) {
  let is_collapsed = list.contains(model.collapsed_sections, category)
  let total_count = list.length(items)
  let done_count = list.count(items, fn(i) { i.checked })
  let pending_count = total_count - done_count
  let all_done = total_count > 0 && done_count == total_count

  html.section([attribute.class("category-section")], [
    html.div(
      [
        attribute.class("category-header"),
        event.on_click(UserToggledSection(category)),
      ],
      [
        html.div([attribute.class("category-title")], [
          html.span(
            [
              attribute.classes([
                #("category-arrow", True),
                #("collapsed", is_collapsed),
              ]),
            ],
            [element.text(case is_collapsed {
              True -> "▶"
              False -> "▼"
            })],
          ),
          element.text(category),
        ]),
        html.span(
          [
            attribute.classes([
              #("category-badge", True),
              #("all-done", all_done),
            ]),
          ],
          [
            element.text(case all_done {
              True -> "✓ Completa"
              False ->
                int.to_string(pending_count)
                <> " pendiente"
                <> case pending_count == 1 {
                  True -> ""
                  False -> "s"
                }
            }),
          ],
        ),
      ],
    ),
    case is_collapsed {
      True -> element.none()
      False ->
        html.ul(
          [attribute.class("list category-list")],
          list.map(items, fn(item) { view_item(model, item) }),
        )
    },
  ])
}

fn view(model: Model) -> Element(Message) {
  let active_categories =
    list.filter(standard_categories, fn(cat) {
      list.any(model.items, fn(item) { item.category == cat })
    })

  let uncategorized_items =
    list.filter(model.items, fn(item) {
      !list.contains(standard_categories, item.category)
    })

  let sections =
    list.map(active_categories, fn(cat) {
      let cat_items = list.filter(model.items, fn(item) { item.category == cat })
      view_category_section(model, cat, cat_items)
    })

  let all_sections = case uncategorized_items {
    [] -> sections
    _ ->
      list.append(sections, [
        view_category_section(model, "📦 Otros", uncategorized_items),
      ])
  }

  html.div([attribute.class("frigo-container")], [
    // Top bar
    html.header([attribute.class("app-header")], [
      html.button(
        [
          attribute.class("room-badge"),
          event.on_click(UserOpenedSwitchModal),
          attribute.title("Cambiar de lista"),
        ],
        [
          html.span(
            [
              attribute.classes([
                #("status-dot", True),
                #("online", model.connected),
                #("offline", !model.connected),
              ]),
            ],
            [],
          ),
          html.span([attribute.class("room-name")], [
            element.text(model.room_id),
          ]),
          html.span([attribute.class("room-edit-icon")], [element.text("▾")]),
        ],
      ),
      html.button(
        [
          attribute.class("share-btn"),
          event.on_click(UserOpenedShareModal),
          attribute.title("Compartir esta lista"),
        ],
        [element.text("👥 Compartir")],
      ),
    ]),
    // Add item form
    html.form([attribute.class("form"), event.on_submit(UserAddedItem)], [
      html.input([
        attribute.name("input_form"),
        attribute.placeholder("Producto (ej: Leche)..."),
        attribute.required(True),
        attribute.class("input"),
      ]),
      html.input([
        attribute.name("input_count"),
        attribute.type_("number"),
        attribute.class("input-number"),
        attribute.min("1"),
        attribute.value("1"),
      ]),
      html.button([attribute.type_("submit"), attribute.class("btn")], [
        element.text("Añadir"),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("btn btn-danger"),
          event.on_click(UserAskedToDeleteList),
          attribute.title("Vaciar toda la lista"),
        ],
        [element.text("Vaciar")],
      ),
    ]),
    // OCR Section
    html.div([attribute.class("scan-section")], [
      html.label(
        [
          attribute.class("btn btn-scan"),
          attribute.attribute("for", "scan-input"),
        ],
        [
          element.text(case model.scanning {
            True -> "📷 Escaneando imagen..."
            False -> "📷 Escanear lista en papel"
          }),
        ],
      ),
      html.input([
        attribute.type_("file"),
        attribute.id("scan-input"),
        attribute.attribute("accept", "image/*"),
        attribute.attribute("capture", "environment"),
        attribute.attribute("hidden", ""),
        event.on("change", decode.map(decode.dynamic, UserSelectedImage)),
      ]),
    ]),
    // Categories and Items
    case model.items {
      [] ->
        html.div([attribute.class("empty-list-hint")], [
          element.text("Tu lista está vacía. Añade productos o escanea una foto con 📷"),
        ])
      _ -> html.div([attribute.class("categories-container")], all_sections)
    },
    view_share_modal(model),
    view_switch_modal(model),
    view_delete_modal(model),
  ])
}

// =============================================================================
// Initialization
// =============================================================================

fn init(_initial: Int) -> #(Model, effect.Effect(Message)) {
  let assert Ok(local) = varasto.local()
  let storage = varasto.new(local, reader(), writer)
  let room = get_active_room_id()

  #(
    Model(
      items_storage: storage,
      items: load_room_items(storage, room),
      scanning: False,
      editing: None,
      confirm_delete_list: False,
      draft_name: "",
      draft_amount: "",
      draft_category: "📦 Otros",
      collapsed_sections: [],
      room_id: room,
      connected: False,
      show_share_modal: False,
      show_switch_modal: False,
      switch_room_input: "",
      copied_toast: False,
    ),
    effect.batch([
      effect.from(fn(dispatch) {
        enable_swipe_to_delete(fn(name) { dispatch(UserDeletedItem(name)) })
      }),
      start_sync_effect(room),
    ]),
  )
}

// =============================================================================
// Decoders & Encoders
// =============================================================================

pub fn reader() {
  decode.list({
    use name <- decode.field("name", decode.string)
    use amount <- decode.field("number", decode.int)
    use checked <- decode.field("checked", decode.bool)
    use category <- decode.optional_field("category", "📦 Otros", decode.string)
    decode.success(Item(name:, amount:, checked:, category:))
  })
}

pub fn writer(items: List(Item)) {
  use item <- json.array(items)
  json.object([
    #("checked", json.bool(item.checked)),
    #("name", json.string(item.name)),
    #("number", json.int(item.amount)),
    #("category", json.string(item.category)),
  ])
}
