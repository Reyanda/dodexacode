import Foundation

// MARK: - Thesaurus: Internal Synonym Index Engine
// Maps concepts to all their synonyms, narrower/broader/related terms,
// abbreviations, spelling variants, and truncation patterns.
// Like MeSH trees but universal — works across any domain.
// Persists to .dodexabash/thesaurus/. Supports MeSH API lookup.

// MARK: - Concept Node

public struct ConceptNode: Codable, Sendable {
    public let id: String
    public var preferred: String           // canonical form
    public var synonyms: [String]          // equivalent terms
    public var narrower: [String]          // more specific (children)
    public var broader: [String]           // more general (parents)
    public var related: [String]           // associated concepts
    public var abbreviations: [String]     // acronyms: MI, AMI, T2DM
    public var spellingVariants: [String]  // alternate spellings
    public var truncations: [String]       // wildcard forms: myocardi*, diabet*
    public var domain: String              // medicine, computing, general, social, economics
    public var source: String              // "seed", "mesh-api", "user", "brain", "wikidata", "acm"

    // MARK: - Cross-Vocabulary Identifiers (Universal Concept Graph)

    // Medicine
    public var meshId: String?             // NLM MeSH descriptor: D003924
    public var meshTreeNumbers: [String]   // MeSH hierarchy: ["C18.452.394.750.149", "C19.246.300"]
    public var meshEntryTerms: [String]    // All MeSH entry terms (synonyms from NLM)
    public var meshSubheadings: [String]   // Allowable qualifiers: ["/therapy", "/epidemiology"]
    public var emtreePreferred: String?    // Embase Emtree preferred term
    public var cinahlHeading: String?      // CINAHL Subject Heading (EBSCO)
    public var snomedId: String?           // SNOMED CT concept ID
    public var icd10: [String]             // ICD-10 codes: ["E11", "E11.9"]

    // Universal
    public var umlsCUI: String?            // UMLS Concept Unique Identifier: C0011860
    public var wikidataId: String?         // Wikidata entity: Q3025883
    public var lcsh: String?               // Library of Congress Subject Heading

    // Computing
    public var acmCCS: String?             // ACM Computing Classification: 10.1145/3383583
    public var ieeeKeyword: String?        // IEEE keyword
    public var arxivCategory: String?      // arXiv category: cs.AI, q-bio.GN

    // Social Science
    public var ericDescriptor: String?     // ERIC thesaurus descriptor
    public var psycInfoTerm: String?       // APA PsycINFO controlled term

    public init(id: String, preferred: String, synonyms: [String] = [], narrower: [String] = [],
                broader: [String] = [], related: [String] = [], abbreviations: [String] = [],
                spellingVariants: [String] = [], truncations: [String] = [],
                domain: String = "general", meshId: String? = nil, source: String = "seed") {
        self.id = id
        self.preferred = preferred
        self.synonyms = synonyms
        self.narrower = narrower
        self.broader = broader
        self.related = related
        self.abbreviations = abbreviations
        self.spellingVariants = spellingVariants
        self.truncations = truncations
        self.domain = domain
        self.source = source
        self.meshId = meshId
        // Initialize all cross-vocabulary fields
        self.meshTreeNumbers = []
        self.meshEntryTerms = []
        self.meshSubheadings = []
        self.emtreePreferred = nil
        self.cinahlHeading = nil
        self.snomedId = nil
        self.icd10 = []
        self.umlsCUI = nil
        self.wikidataId = nil
        self.lcsh = nil
        self.acmCCS = nil
        self.ieeeKeyword = nil
        self.arxivCategory = nil
        self.ericDescriptor = nil
        self.psycInfoTerm = nil
    }

    public var allTerms: [String] {
        var terms = [preferred] + synonyms + abbreviations + spellingVariants + meshEntryTerms
        terms.append(contentsOf: narrower)
        if let emtree = emtreePreferred { terms.append(emtree) }
        if let cinahl = cinahlHeading { terms.append(cinahl) }
        return Array(Set(terms))
    }

    /// All terms including narrower (for explosion)
    public func exploded(depth: Int = 1) -> [String] {
        var terms = [preferred] + synonyms + abbreviations + spellingVariants + meshEntryTerms
        if depth > 0 { terms.append(contentsOf: narrower) }
        if let emtree = emtreePreferred { terms.append(emtree) }
        if let cinahl = cinahlHeading { terms.append(cinahl) }
        return Array(Set(terms)).sorted()
    }

    /// Cross-vocabulary summary
    public var vocabSummary: String {
        var parts: [String] = []
        if let mesh = meshId { parts.append("MeSH:\(mesh)") }
        if !meshTreeNumbers.isEmpty { parts.append("Tree:\(meshTreeNumbers.first ?? "")") }
        if let cui = umlsCUI { parts.append("UMLS:\(cui)") }
        if let emtree = emtreePreferred { parts.append("Emtree:\(emtree)") }
        if let cinahl = cinahlHeading { parts.append("CINAHL:\(cinahl)") }
        if let wikidata = wikidataId { parts.append("Wikidata:\(wikidata)") }
        if let acm = acmCCS { parts.append("ACM:\(acm)") }
        if let arxiv = arxivCategory { parts.append("arXiv:\(arxiv)") }
        if let eric = ericDescriptor { parts.append("ERIC:\(eric)") }
        return parts.isEmpty ? "No cross-refs" : parts.joined(separator: " | ")
    }
}

// MARK: - Thesaurus Store

public final class Thesaurus: @unchecked Sendable {
    private let directory: URL
    private var concepts: [String: ConceptNode] = [:]  // lowercased preferred → node
    private var aliasIndex: [String: String] = [:]      // any term → preferred term
    private let browser: WebBrowser

    public init(directory: URL) {
        self.directory = directory
        self.browser = WebBrowser()
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        if concepts.isEmpty { seedDefaultVocabulary() }
    }

    // MARK: - Lookup

    public func lookup(_ term: String) -> ConceptNode? {
        let lower = term.lowercased()
        // Exact match on preferred term
        if let node = concepts[lower] { return node }
        // Alias match (any synonym → preferred)
        if let preferred = aliasIndex[lower] { return concepts[preferred] }
        // Fuzzy: prefix match
        let prefix = concepts.keys.first { $0.hasPrefix(lower) || lower.hasPrefix($0) }
        if let p = prefix { return concepts[p] }
        return nil
    }

    /// Explode a term: return all synonyms + narrower terms + truncations
    public func explode(_ term: String, depth: Int = 1) -> [String] {
        guard let node = lookup(term) else {
            // No thesaurus entry — return original + basic truncation
            let base = term.lowercased()
            if base.count > 4 {
                return [term, String(base.prefix(base.count - 2)) + "*"]
            }
            return [term]
        }

        var terms = node.exploded(depth: depth)

        // Recursively explode narrower terms (depth - 1)
        if depth > 0 {
            for narrow in node.narrower {
                if let child = lookup(narrow) {
                    terms.append(contentsOf: child.exploded(depth: 0))
                }
            }
        }

        // Add truncations
        terms.append(contentsOf: node.truncations)

        return Array(Set(terms)).sorted()
    }

    /// Build Boolean OR string from explosion
    public func explodeToBoolean(_ term: String, depth: Int = 1) -> String {
        let terms = explode(term, depth: depth)
        if terms.count == 1 { return terms[0] }

        return "(" + terms.map { t in
            if t.contains(" ") { return "\"\(t)\"" }
            return t
        }.joined(separator: " OR ") + ")"
    }

    // MARK: - Add Concepts

    @discardableResult
    public func addConcept(_ node: ConceptNode) -> ConceptNode {
        let key = node.preferred.lowercased()
        concepts[key] = node
        // Build alias index
        for term in node.allTerms {
            aliasIndex[term.lowercased()] = key
        }
        persist()
        return node
    }

    public func addSynonym(to term: String, synonym: String) {
        let lower = term.lowercased()
        let key = aliasIndex[lower] ?? lower
        if var node = concepts[key] {
            if !node.synonyms.contains(synonym) {
                node.synonyms.append(synonym)
                concepts[key] = node
                aliasIndex[synonym.lowercased()] = key
                persist()
            }
        }
    }

    public func addNarrower(to term: String, child: String) {
        let lower = term.lowercased()
        let key = aliasIndex[lower] ?? lower
        if var node = concepts[key] {
            if !node.narrower.contains(child) {
                node.narrower.append(child)
                concepts[key] = node
                persist()
            }
        }
    }

    // MARK: - MeSH API Integration

    /// Fetch synonyms from NLM MeSH API (free, no key required)
    public func fetchMeSH(_ term: String) -> ConceptNode? {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let url = "https://id.nlm.nih.gov/mesh/lookup/descriptor?label=\(encoded)&match=contains&limit=5"

        let response = browser.client.get(url)
        guard response.isSuccess else { return nil }

        // Parse JSON-LD response
        guard let data = response.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first else { return nil }

        let label = first["label"] as? String ?? term
        let resourceUri = first["resource"] as? String ?? ""
        let meshId = resourceUri.components(separatedBy: "/").last

        // Fetch full descriptor for entry terms (synonyms)
        var synonyms: [String] = []
        if let meshId {
            let descUrl = "https://id.nlm.nih.gov/mesh/lookup/details?descriptor=\(meshId)"
            let descResponse = browser.client.get(descUrl)
            if descResponse.isSuccess,
               let descData = descResponse.body.data(using: .utf8),
               let descJson = try? JSONSerialization.jsonObject(with: descData) as? [String: Any] {
                if let terms = descJson["terms"] as? [[String: Any]] {
                    synonyms = terms.compactMap { $0["label"] as? String }
                }
            }
        }

        let node = ConceptNode(
            id: meshId ?? shortId(),
            preferred: label,
            synonyms: synonyms.filter { $0.lowercased() != label.lowercased() },
            narrower: [],
            broader: [],
            related: [],
            abbreviations: [],
            spellingVariants: [],
            truncations: generateTruncations(label),
            domain: "medicine",
            meshId: meshId,
            source: "mesh-api"
        )

        addConcept(node)
        return node
    }

    // MARK: - Stats

    public var conceptCount: Int { concepts.count }
    public var aliasCount: Int { aliasIndex.count }

    public func stats() -> (concepts: Int, aliases: Int, domains: [String: Int]) {
        var domains: [String: Int] = [:]
        for node in concepts.values {
            domains[node.domain, default: 0] += 1
        }
        return (concepts.count, aliasIndex.count, domains)
    }

    public func conceptsInDomain(_ domain: String) -> [ConceptNode] {
        concepts.values.filter { $0.domain.lowercased() == domain.lowercased() }
            .sorted { $0.preferred < $1.preferred }
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(concepts.values)) else { return }
        try? data.write(to: directory.appendingPathComponent("concepts.json"), options: .atomic)
    }

    private func load() {
        let url = directory.appendingPathComponent("concepts.json")
        guard let data = try? Data(contentsOf: url),
              let nodes = try? JSONDecoder().decode([ConceptNode].self, from: data) else { return }
        for node in nodes {
            let key = node.preferred.lowercased()
            concepts[key] = node
            for term in node.allTerms {
                aliasIndex[term.lowercased()] = key
            }
        }
    }

    // MARK: - Helpers

    private func generateTruncations(_ term: String) -> [String] {
        let words = term.lowercased().split(separator: " ").map(String.init)
        return words.filter { $0.count > 4 }.map { String($0.prefix($0.count - 2)) + "*" }
    }

    private func shortId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = bytes.withUnsafeMutableBufferPointer { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Seed Vocabulary

    private func seedDefaultVocabulary() {
        seedMedical()
        seedEpidemiology()
        seedComputing()
        seedPublicHealth()
        seedPharmacology()
        seedSocialScience()
        seedStatistics()
        persist()
    }

    private func seedMedical() {
        let d = "medicine"
        let s = "seed"
        addConcept(ConceptNode(id: "M001", preferred: "Myocardial Infarction", synonyms: ["heart attack", "cardiac infarction", "coronary thrombosis"], narrower: ["STEMI", "NSTEMI", "silent MI"], broader: ["Cardiovascular Disease"], related: ["Troponin", "Chest Pain", "Coronary Artery Disease"], abbreviations: ["MI", "AMI"], spellingVariants: [], truncations: ["myocardi*", "infarct*"], domain: d, meshId: "D009203", source: s))
        addConcept(ConceptNode(id: "M002", preferred: "Diabetes Mellitus Type 2", synonyms: ["type 2 diabetes", "non-insulin dependent diabetes", "adult-onset diabetes", "T2DM", "NIDDM"], narrower: ["diabetic nephropathy", "diabetic retinopathy", "diabetic neuropathy"], broader: ["Diabetes Mellitus", "Endocrine Disease"], related: ["insulin resistance", "HbA1c", "metformin", "obesity"], abbreviations: ["T2DM", "DM2", "NIDDM"], spellingVariants: ["type II diabetes"], truncations: ["diabet*"], domain: d, meshId: "D003924", source: s))
        addConcept(ConceptNode(id: "M003", preferred: "Hypertension", synonyms: ["high blood pressure", "elevated blood pressure", "arterial hypertension"], narrower: ["essential hypertension", "resistant hypertension", "malignant hypertension", "pulmonary hypertension", "gestational hypertension"], broader: ["Cardiovascular Disease"], related: ["blood pressure", "antihypertensive", "systolic", "diastolic"], abbreviations: ["HTN", "HBP"], spellingVariants: [], truncations: ["hypertens*"], domain: d, meshId: "D006973", source: s))
        addConcept(ConceptNode(id: "M004", preferred: "Metformin", synonyms: ["glucophage", "dimethylbiguanide", "Fortamet", "Glumetza", "Riomet"], narrower: [], broader: ["Biguanides", "Hypoglycemic Agent"], related: ["type 2 diabetes", "insulin resistance", "HbA1c"], abbreviations: [], spellingVariants: [], truncations: ["metformin*"], domain: d, meshId: "D008687", source: s))
        addConcept(ConceptNode(id: "M005", preferred: "Mortality", synonyms: ["death", "fatality", "lethality"], narrower: ["cardiovascular mortality", "all-cause mortality", "cancer mortality", "infant mortality", "maternal mortality", "perioperative mortality"], broader: ["Health Outcome"], related: ["survival", "life expectancy", "case fatality rate"], abbreviations: [], spellingVariants: [], truncations: ["mortalit*", "death*"], domain: d, meshId: "D009026", source: s))
        addConcept(ConceptNode(id: "M006", preferred: "Randomized Controlled Trial", synonyms: ["RCT", "randomised controlled trial", "randomized clinical trial", "controlled clinical trial"], narrower: ["cluster RCT", "crossover trial", "factorial trial", "adaptive trial", "pragmatic trial"], broader: ["Clinical Trial", "Experimental Study"], related: ["randomization", "blinding", "allocation concealment", "intention to treat"], abbreviations: ["RCT"], spellingVariants: ["randomised controlled trial"], truncations: ["randomi*"], domain: d, meshId: "D016449", source: s))
        addConcept(ConceptNode(id: "M007", preferred: "Systematic Review", synonyms: ["systematic literature review", "evidence synthesis", "knowledge synthesis"], narrower: ["meta-analysis", "scoping review", "rapid review", "umbrella review", "living systematic review"], broader: ["Evidence Synthesis", "Research Methodology"], related: ["PRISMA", "Cochrane", "protocol", "risk of bias", "GRADE"], abbreviations: ["SR"], spellingVariants: [], truncations: ["systematic review*"], domain: d, meshId: "D000078182", source: s))
        addConcept(ConceptNode(id: "M008", preferred: "Obesity", synonyms: ["overweight", "adiposity", "excess body weight"], narrower: ["morbid obesity", "childhood obesity", "central obesity", "visceral obesity"], broader: ["Metabolic Disease", "Nutritional Disease"], related: ["BMI", "body mass index", "bariatric", "waist circumference"], abbreviations: [], spellingVariants: [], truncations: ["obes*", "adipos*"], domain: d, meshId: "D009765", source: s))
        addConcept(ConceptNode(id: "M009", preferred: "COVID-19", synonyms: ["SARS-CoV-2 infection", "coronavirus disease 2019", "novel coronavirus"], narrower: ["long COVID", "COVID pneumonia", "MIS-C"], broader: ["Coronavirus Infection", "Respiratory Infection"], related: ["SARS-CoV-2", "pandemic", "lockdown", "vaccine", "mRNA vaccine"], abbreviations: ["COVID"], spellingVariants: ["Covid-19", "covid19"], truncations: ["covid*", "sars-cov*"], domain: d, meshId: "D000086382", source: s))
        addConcept(ConceptNode(id: "M010", preferred: "CRISPR", synonyms: ["CRISPR-Cas9", "gene editing", "genome editing", "clustered regularly interspaced short palindromic repeats"], narrower: ["base editing", "prime editing", "CRISPRi", "CRISPRa"], broader: ["Gene Therapy", "Molecular Biology"], related: ["guide RNA", "Cas9", "off-target effects", "gene drive"], abbreviations: ["CRISPR"], spellingVariants: [], truncations: ["crispr*"], domain: d, meshId: "D000071836", source: s))
    }

    private func seedEpidemiology() {
        let d = "epidemiology"
        let s = "seed"
        addConcept(ConceptNode(id: "E001", preferred: "Incidence", synonyms: ["incidence rate", "new cases", "attack rate"], narrower: ["cumulative incidence", "incidence density", "person-time incidence"], broader: ["Disease Frequency"], related: ["prevalence", "risk", "hazard rate"], abbreviations: ["IR"], spellingVariants: [], truncations: ["inciden*"], domain: d, meshId: "D015994", source: s))
        addConcept(ConceptNode(id: "E002", preferred: "Prevalence", synonyms: ["disease prevalence", "frequency"], narrower: ["point prevalence", "period prevalence", "lifetime prevalence"], broader: ["Disease Frequency"], related: ["incidence", "burden of disease"], abbreviations: [], spellingVariants: [], truncations: ["prevalen*"], domain: d, meshId: "D015995", source: s))
        addConcept(ConceptNode(id: "E003", preferred: "Odds Ratio", synonyms: ["OR", "cross-product ratio"], narrower: ["adjusted odds ratio", "crude odds ratio", "conditional odds ratio"], broader: ["Measure of Association"], related: ["logistic regression", "case-control study", "relative risk"], abbreviations: ["OR", "aOR"], spellingVariants: [], truncations: ["odds ratio*"], domain: d, meshId: "D016017", source: s))
        addConcept(ConceptNode(id: "E004", preferred: "Relative Risk", synonyms: ["risk ratio", "RR", "rate ratio"], narrower: ["adjusted relative risk", "crude relative risk"], broader: ["Measure of Association"], related: ["cohort study", "odds ratio", "absolute risk"], abbreviations: ["RR", "aRR"], spellingVariants: [], truncations: ["relative risk*", "risk ratio*"], domain: d, meshId: "D012306", source: s))
        addConcept(ConceptNode(id: "E005", preferred: "Confounding", synonyms: ["confounding variable", "confounder", "confounding bias"], narrower: ["residual confounding", "unmeasured confounding", "confounding by indication"], broader: ["Bias"], related: ["adjustment", "stratification", "propensity score", "DAG"], abbreviations: [], spellingVariants: [], truncations: ["confound*"], domain: d, meshId: "D015986", source: s))
        addConcept(ConceptNode(id: "E006", preferred: "Cohort Study", synonyms: ["prospective study", "longitudinal study", "follow-up study"], narrower: ["prospective cohort", "retrospective cohort", "birth cohort", "historical cohort"], broader: ["Observational Study"], related: ["person-time", "hazard ratio", "survival analysis", "loss to follow-up"], abbreviations: [], spellingVariants: [], truncations: ["cohort*"], domain: d, meshId: "D015331", source: s))
        addConcept(ConceptNode(id: "E007", preferred: "Case-Control Study", synonyms: ["case-referent study", "case-comparison study"], narrower: ["nested case-control", "case-crossover", "matched case-control"], broader: ["Observational Study"], related: ["odds ratio", "selection bias", "recall bias", "matching"], abbreviations: [], spellingVariants: [], truncations: ["case-control*", "case control*"], domain: d, meshId: "D016022", source: s))
        addConcept(ConceptNode(id: "E008", preferred: "Selection Bias", synonyms: ["sampling bias", "volunteer bias", "referral bias"], narrower: ["Berkson bias", "healthy worker effect", "survival bias", "collider bias"], broader: ["Bias"], related: ["external validity", "generalizability", "representativeness"], abbreviations: [], spellingVariants: [], truncations: ["selection bias*"], domain: d, meshId: "D015983", source: s))
        addConcept(ConceptNode(id: "E009", preferred: "Causal Inference", synonyms: ["causal analysis", "causal reasoning"], narrower: ["instrumental variable", "difference-in-differences", "regression discontinuity", "Mendelian randomization"], broader: ["Statistical Methods"], related: ["counterfactual", "DAG", "potential outcomes", "target trial", "Pearl"], abbreviations: ["CI"], spellingVariants: [], truncations: ["causal*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "E010", preferred: "Meta-analysis", synonyms: ["quantitative synthesis", "pooled analysis"], narrower: ["fixed-effects meta-analysis", "random-effects meta-analysis", "network meta-analysis", "IPD meta-analysis"], broader: ["Evidence Synthesis"], related: ["heterogeneity", "I-squared", "forest plot", "funnel plot", "publication bias"], abbreviations: ["MA", "NMA"], spellingVariants: ["meta analysis"], truncations: ["meta-analy*", "meta analy*"], domain: d, meshId: "D015201", source: s))
    }

    private func seedComputing() {
        let d = "computing"
        let s = "seed"
        addConcept(ConceptNode(id: "C001", preferred: "Machine Learning", synonyms: ["ML", "statistical learning", "pattern recognition"], narrower: ["deep learning", "reinforcement learning", "supervised learning", "unsupervised learning", "transfer learning", "federated learning"], broader: ["Artificial Intelligence"], related: ["neural network", "gradient descent", "feature engineering", "overfitting"], abbreviations: ["ML", "DL"], spellingVariants: [], truncations: ["machine learn*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "C002", preferred: "Large Language Model", synonyms: ["LLM", "foundation model", "generative AI", "transformer model"], narrower: ["GPT", "Claude", "Gemini", "Llama", "Mistral"], broader: ["Machine Learning", "NLP"], related: ["tokenization", "attention mechanism", "fine-tuning", "RLHF", "prompt engineering"], abbreviations: ["LLM", "FM"], spellingVariants: [], truncations: ["language model*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "C003", preferred: "API", synonyms: ["application programming interface", "web API", "REST API", "endpoint"], narrower: ["GraphQL", "gRPC", "WebSocket", "REST", "SOAP"], broader: ["Software Architecture"], related: ["HTTP", "JSON", "authentication", "rate limiting"], abbreviations: ["API"], spellingVariants: [], truncations: [], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "C004", preferred: "Database", synonyms: ["data store", "DBMS", "data management system"], narrower: ["relational database", "NoSQL", "graph database", "vector database", "time-series database"], broader: ["Data Management"], related: ["SQL", "indexing", "ACID", "replication", "sharding"], abbreviations: ["DB", "DBMS"], spellingVariants: [], truncations: ["databas*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "C005", preferred: "Cryptography", synonyms: ["encryption", "cipher", "cryptographic"], narrower: ["AES", "RSA", "elliptic curve", "hash function", "digital signature", "TLS", "end-to-end encryption"], broader: ["Security"], related: ["key management", "PKI", "zero-knowledge proof", "blockchain"], abbreviations: [], spellingVariants: [], truncations: ["crypt*", "encrypt*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "C006", preferred: "Neural Network", synonyms: ["artificial neural network", "ANN", "deep neural network", "DNN"], narrower: ["CNN", "RNN", "transformer", "GAN", "autoencoder", "diffusion model", "graph neural network"], broader: ["Machine Learning"], related: ["backpropagation", "activation function", "loss function", "gradient descent"], abbreviations: ["ANN", "DNN", "CNN", "RNN", "GAN"], spellingVariants: [], truncations: ["neural net*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "C007", preferred: "Cloud Computing", synonyms: ["cloud infrastructure", "IaaS", "PaaS", "SaaS"], narrower: ["AWS", "Azure", "GCP", "serverless", "edge computing", "multi-cloud"], broader: ["Computing Infrastructure"], related: ["containerization", "Docker", "Kubernetes", "microservices", "autoscaling"], abbreviations: ["IaaS", "PaaS", "SaaS"], spellingVariants: [], truncations: ["cloud*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "C008", preferred: "Cybersecurity", synonyms: ["information security", "InfoSec", "computer security"], narrower: ["penetration testing", "vulnerability assessment", "incident response", "threat intelligence", "zero trust", "SIEM"], broader: ["Security"], related: ["firewall", "IDS", "malware", "phishing", "ransomware", "CVE"], abbreviations: ["InfoSec", "SIEM", "SOC"], spellingVariants: ["cyber security"], truncations: ["cybersecur*", "infosec*"], domain: d, meshId: nil, source: s))
    }

    // MARK: - Public Health Vocabulary

    private func seedPublicHealth() {
        let d = "public_health"
        let s = "seed"
        addConcept(ConceptNode(id: "PH001", preferred: "Vaccination", synonyms: ["immunization", "immunisation", "inoculation", "vaccine administration"], narrower: ["COVID-19 vaccination", "childhood immunization", "influenza vaccination", "HPV vaccination", "booster dose"], broader: ["Prevention", "Public Health Intervention"], related: ["herd immunity", "vaccine hesitancy", "adverse event", "cold chain"], abbreviations: [], spellingVariants: ["immunisation"], truncations: ["vaccin*", "immuniz*", "immunis*"], domain: d, meshId: "D014611", source: s))
        addConcept(ConceptNode(id: "PH002", preferred: "Health Inequality", synonyms: ["health disparity", "health inequity", "health gap"], narrower: ["racial health disparity", "socioeconomic health gap", "gender health inequality", "rural health disparity"], broader: ["Social Determinants of Health"], related: ["Gini coefficient", "deprivation index", "life expectancy gap", "access to care"], abbreviations: [], spellingVariants: ["health inequalities"], truncations: ["health inequal*", "health dispar*"], domain: d, meshId: "D054624", source: s))
        addConcept(ConceptNode(id: "PH003", preferred: "Pandemic", synonyms: ["global epidemic", "worldwide outbreak"], narrower: ["COVID-19 pandemic", "influenza pandemic", "HIV pandemic"], broader: ["Epidemic", "Disease Outbreak"], related: ["containment", "lockdown", "contact tracing", "surveillance", "preparedness", "WHO"], abbreviations: [], spellingVariants: [], truncations: ["pandemic*"], domain: d, meshId: "D058873", source: s))
        addConcept(ConceptNode(id: "PH004", preferred: "Screening", synonyms: ["mass screening", "population screening", "early detection"], narrower: ["cancer screening", "newborn screening", "genetic screening", "prenatal screening"], broader: ["Prevention", "Secondary Prevention"], related: ["sensitivity", "specificity", "positive predictive value", "number needed to screen"], abbreviations: ["NNS"], spellingVariants: [], truncations: ["screen*"], domain: d, meshId: "D008403", source: s))
        addConcept(ConceptNode(id: "PH005", preferred: "Social Determinants of Health", synonyms: ["SDOH", "social factors in health", "upstream determinants"], narrower: ["poverty", "education level", "housing", "food insecurity", "employment", "social isolation"], broader: ["Population Health"], related: ["health equity", "structural racism", "health literacy", "built environment"], abbreviations: ["SDOH"], spellingVariants: [], truncations: ["social determin*"], domain: d, meshId: "D064890", source: s))
        addConcept(ConceptNode(id: "PH006", preferred: "Surveillance", synonyms: ["disease surveillance", "health surveillance", "epidemiological surveillance", "sentinel surveillance"], narrower: ["syndromic surveillance", "genomic surveillance", "wastewater surveillance", "laboratory surveillance"], broader: ["Public Health Practice"], related: ["notifiable disease", "outbreak detection", "case definition", "reporting"], abbreviations: [], spellingVariants: [], truncations: ["surveillan*"], domain: d, meshId: "D011159", source: s))
        addConcept(ConceptNode(id: "PH007", preferred: "Antimicrobial Resistance", synonyms: ["AMR", "antibiotic resistance", "drug resistance", "multidrug resistance"], narrower: ["MRSA", "ESBL", "carbapenem resistance", "vancomycin resistance", "XDR-TB"], broader: ["Infectious Disease"], related: ["antimicrobial stewardship", "susceptibility testing", "MIC", "biofilm"], abbreviations: ["AMR", "MDR", "XDR", "MRSA"], spellingVariants: [], truncations: ["antimicrobial resistan*", "antibiotic resistan*"], domain: d, meshId: "D000069336", source: s))
    }

    // MARK: - Pharmacology Vocabulary

    private func seedPharmacology() {
        let d = "pharmacology"
        let s = "seed"
        addConcept(ConceptNode(id: "PX001", preferred: "Pharmacokinetics", synonyms: ["drug kinetics", "ADME", "drug disposition"], narrower: ["absorption", "distribution", "metabolism", "excretion", "bioavailability", "half-life", "clearance", "volume of distribution"], broader: ["Pharmacology"], related: ["Cmax", "Tmax", "AUC", "first-pass effect", "protein binding"], abbreviations: ["PK", "ADME"], spellingVariants: [], truncations: ["pharmacokinet*"], domain: d, meshId: "D010599", source: s))
        addConcept(ConceptNode(id: "PX002", preferred: "Pharmacodynamics", synonyms: ["drug action", "drug effect", "dose-response relationship"], narrower: ["receptor binding", "enzyme inhibition", "agonism", "antagonism", "EC50", "IC50"], broader: ["Pharmacology"], related: ["therapeutic window", "dose-response curve", "potency", "efficacy"], abbreviations: ["PD"], spellingVariants: [], truncations: ["pharmacodynam*"], domain: d, meshId: "D010600", source: s))
        addConcept(ConceptNode(id: "PX003", preferred: "Adverse Drug Reaction", synonyms: ["adverse event", "side effect", "drug toxicity", "adverse effect"], narrower: ["type A reaction", "type B reaction", "drug allergy", "anaphylaxis", "hepatotoxicity", "nephrotoxicity", "QT prolongation"], broader: ["Drug Safety"], related: ["pharmacovigilance", "yellow card", "FAERS", "causality assessment", "Naranjo scale"], abbreviations: ["ADR", "ADE", "AE", "SAE"], spellingVariants: [], truncations: ["adverse drug*", "adverse event*", "side effect*"], domain: d, meshId: "D064420", source: s))
        addConcept(ConceptNode(id: "PX004", preferred: "Drug Interaction", synonyms: ["drug-drug interaction", "DDI", "medication interaction"], narrower: ["CYP450 interaction", "P-glycoprotein interaction", "pharmacokinetic interaction", "pharmacodynamic interaction"], broader: ["Drug Safety"], related: ["cytochrome P450", "enzyme induction", "enzyme inhibition", "polypharmacy"], abbreviations: ["DDI"], spellingVariants: [], truncations: ["drug interact*"], domain: d, meshId: "D004347", source: s))
        addConcept(ConceptNode(id: "PX005", preferred: "Clinical Trial Phase", synonyms: ["drug development phase", "trial phase"], narrower: ["Phase I trial", "Phase II trial", "Phase III trial", "Phase IV trial", "preclinical study"], broader: ["Drug Development"], related: ["IND", "NDA", "FDA approval", "EMA", "regulatory"], abbreviations: [], spellingVariants: [], truncations: ["clinical trial phase*"], domain: d, meshId: "D002986", source: s))
    }

    // MARK: - Social Science Vocabulary

    private func seedSocialScience() {
        let d = "social_science"
        let s = "seed"
        addConcept(ConceptNode(id: "SS001", preferred: "Inequality", synonyms: ["disparity", "inequity", "stratification"], narrower: ["income inequality", "wealth inequality", "educational inequality", "gender inequality", "racial inequality", "health inequality", "digital divide"], broader: ["Social Structure"], related: ["Gini coefficient", "poverty", "social mobility", "redistribution"], abbreviations: [], spellingVariants: ["inequalities"], truncations: ["inequal*", "dispar*", "inequit*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "SS002", preferred: "Migration", synonyms: ["immigration", "emigration", "population movement", "human mobility"], narrower: ["forced migration", "labor migration", "refugee", "asylum seeker", "internal displacement", "brain drain", "circular migration"], broader: ["Demography"], related: ["remittance", "integration", "xenophobia", "diaspora", "border"], abbreviations: ["IDP"], spellingVariants: [], truncations: ["migrat*", "immigrat*", "emigrat*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "SS003", preferred: "Climate Change", synonyms: ["global warming", "climate crisis", "climate emergency"], narrower: ["sea level rise", "extreme weather", "drought", "flooding", "heat wave", "ocean acidification", "deforestation"], broader: ["Environmental Science"], related: ["carbon emissions", "greenhouse gas", "Paris Agreement", "adaptation", "mitigation", "net zero"], abbreviations: ["GHG"], spellingVariants: [], truncations: ["climate chang*", "global warm*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "SS004", preferred: "Governance", synonyms: ["public administration", "government", "public policy"], narrower: ["democratic governance", "corporate governance", "e-governance", "local governance", "global governance"], broader: ["Political Science"], related: ["accountability", "transparency", "corruption", "regulation", "decentralization"], abbreviations: [], spellingVariants: [], truncations: ["governan*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "SS005", preferred: "Behavioral Economics", synonyms: ["behavioural economics", "choice architecture", "nudge theory"], narrower: ["loss aversion", "anchoring", "framing effect", "present bias", "default effect"], broader: ["Economics"], related: ["Kahneman", "Thaler", "prospect theory", "bounded rationality", "heuristics"], abbreviations: [], spellingVariants: ["behavioural economics"], truncations: ["behavio*ral econom*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "SS006", preferred: "Qualitative Research", synonyms: ["qualitative study", "qualitative inquiry", "interpretive research"], narrower: ["grounded theory", "phenomenology", "ethnography", "case study", "narrative inquiry", "action research", "thematic analysis"], broader: ["Research Methodology"], related: ["interview", "focus group", "coding", "saturation", "reflexivity", "triangulation"], abbreviations: [], spellingVariants: [], truncations: ["qualitative*"], domain: d, meshId: nil, source: s))
    }

    // MARK: - Statistics Vocabulary

    private func seedStatistics() {
        let d = "statistics"
        let s = "seed"
        addConcept(ConceptNode(id: "ST001", preferred: "Regression Analysis", synonyms: ["regression model", "regression modeling"], narrower: ["linear regression", "logistic regression", "Cox regression", "Poisson regression", "negative binomial regression", "multilevel model", "mixed effects model", "quantile regression"], broader: ["Statistical Method"], related: ["coefficient", "p-value", "confidence interval", "R-squared", "residual"], abbreviations: [], spellingVariants: ["regression modelling"], truncations: ["regress*"], domain: d, meshId: "D012044", source: s))
        addConcept(ConceptNode(id: "ST002", preferred: "Survival Analysis", synonyms: ["time-to-event analysis", "failure time analysis"], narrower: ["Kaplan-Meier", "Cox proportional hazards", "competing risks", "accelerated failure time", "log-rank test", "Nelson-Aalen"], broader: ["Statistical Method"], related: ["hazard ratio", "censoring", "median survival", "survival curve", "person-time"], abbreviations: ["KM", "HR"], spellingVariants: [], truncations: ["surviv*"], domain: d, meshId: "D016019", source: s))
        addConcept(ConceptNode(id: "ST003", preferred: "Bayesian Analysis", synonyms: ["Bayesian inference", "Bayesian statistics", "Bayesian approach"], narrower: ["MCMC", "Gibbs sampling", "Bayesian network", "hierarchical Bayesian", "empirical Bayes", "Bayesian meta-analysis"], broader: ["Statistical Method"], related: ["prior", "posterior", "likelihood", "credible interval", "BIC", "Bayes factor"], abbreviations: ["MCMC"], spellingVariants: [], truncations: ["bayesian*"], domain: d, meshId: "D001499", source: s))
        addConcept(ConceptNode(id: "ST004", preferred: "Propensity Score", synonyms: ["propensity score matching", "PSM", "propensity score analysis"], narrower: ["PS matching", "PS stratification", "PS weighting", "IPTW", "PS trimming", "overlap weighting"], broader: ["Causal Inference"], related: ["confounding", "balance", "standardized mean difference", "observational study", "ATT", "ATE"], abbreviations: ["PS", "PSM", "IPTW", "ATT", "ATE"], spellingVariants: [], truncations: ["propensity scor*"], domain: d, meshId: nil, source: s))
        addConcept(ConceptNode(id: "ST005", preferred: "Missing Data", synonyms: ["incomplete data", "missing values", "nonresponse"], narrower: ["MCAR", "MAR", "MNAR", "multiple imputation", "inverse probability weighting", "complete case analysis", "last observation carried forward"], broader: ["Data Quality"], related: ["imputation", "sensitivity analysis", "pattern mixture", "selection model"], abbreviations: ["MCAR", "MAR", "MNAR", "MI", "LOCF", "IPW"], spellingVariants: [], truncations: ["missing dat*", "missing value*", "imputat*"], domain: d, meshId: nil, source: s))
    }
}
