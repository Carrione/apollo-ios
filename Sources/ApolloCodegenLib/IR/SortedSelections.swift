import Foundation
import OrderedCollections
import ApolloUtils

extension IR {
  class DirectSelections: Equatable, CustomDebugStringConvertible {

    fileprivate(set) var fields: OrderedDictionary<String, Field> = [:]
    fileprivate(set) var conditionalSelectionSets: OrderedDictionary<ScopeCondition, SelectionSet> = [:]
    fileprivate(set) var fragments: OrderedDictionary<String, FragmentSpread> = [:]

    init() {}

    init(
      fields: [Field] = [],
      conditionalSelectionSets: [SelectionSet] = [],
      fragments: [FragmentSpread] = []
    ) {
      mergeIn(fields)
      mergeIn(conditionalSelectionSets)
      mergeIn(fragments)
    }

    init(
      fields: OrderedDictionary<String, Field> = [:],
      conditionalSelectionSets: OrderedDictionary<ScopeCondition, SelectionSet> = [:],
      fragments: OrderedDictionary<String, FragmentSpread> = [:]
    ) {
      mergeIn(fields.values)
      mergeIn(conditionalSelectionSets.values)
      mergeIn(fragments.values)
    }

    func mergeIn(_ selections: DirectSelections) {
      mergeIn(selections.fields.values)
      mergeIn(selections.conditionalSelectionSets.values)
      mergeIn(selections.fragments.values)
    }

    func mergeIn(_ field: Field) {
      let keyInScope = field.hashForSelectionSetScope

      if let existingField = fields[keyInScope] {
        existingField.inclusionConditions =
        (existingField.inclusionConditions || field.inclusionConditions)

        if let existingField = existingField as? EntityField,
           let field = field as? EntityField {
          existingField.selectionSet.selections.direct!
            .mergeIn(field.selectionSet.selections.direct!)
        }

      } else {
        fields[keyInScope] = field
      }
    }

    func mergeIn(_ conditionalSelectionSet: SelectionSet) {
      #warning("""
      TODO: I think this is wrong. TDD.

      The last Scope Condition i think is not enough info.
      You'll need the parentType no matter what,
      PLUS (I think) ALL the nested inclusion conditions combined.
      """)
      let scopeCondition = conditionalSelectionSet.typeScope.typePath.last.value

      if let existingTypeCase = conditionalSelectionSets[scopeCondition] {
        existingTypeCase.selections.direct!
          .mergeIn(conditionalSelectionSet.selections.direct!)

      } else {
        conditionalSelectionSets[scopeCondition] = conditionalSelectionSet
      }
    }

    func mergeIn(_ fragment: FragmentSpread) {
      fragments[fragment.hashForSelectionSetScope] = fragment
    }

    func mergeIn<T: Sequence>(_ fields: T) where T.Element == Field {
      fields.forEach { mergeIn($0) }
    }

    func mergeIn<T: Sequence>(_ conditionalSelectionSets: T) where T.Element == SelectionSet {
      conditionalSelectionSets.forEach { mergeIn($0) }
    }

    func mergeIn<T: Sequence>(_ fragments: T) where T.Element == FragmentSpread {
      fragments.forEach { mergeIn($0) }
    }

    var isEmpty: Bool {
      fields.isEmpty && conditionalSelectionSets.isEmpty && fragments.isEmpty
    }

    static func == (lhs: DirectSelections, rhs: DirectSelections) -> Bool {
      lhs.fields == rhs.fields &&
      lhs.conditionalSelectionSets == rhs.conditionalSelectionSets &&
      lhs.fragments == rhs.fragments
    }

    var debugDescription: String {
      """
      Fields: \(fields.values.elements)
      TypeCases: \(conditionalSelectionSets.values.elements.map(\.typeInfo.parentType))
      Fragments: \(fragments.values.elements.map(\.definition.name))
      """
    }

    var readOnlyView: ReadOnly {
      ReadOnly(value: self)
    }

    struct ReadOnly {
      fileprivate let value: DirectSelections

      var fields: OrderedDictionary<String, Field> { value.fields }
      var conditionalSelectionSets: OrderedDictionary<ScopeCondition, SelectionSet> { value.conditionalSelectionSets }
      var fragments: OrderedDictionary<String, FragmentSpread> { value.fragments }
    }

  }

  class MergedSelections: Equatable, CustomDebugStringConvertible {

    struct MergedSource: Hashable {
      let typeInfo: SelectionSet.TypeInfo
      unowned let fragment: FragmentSpread?
    }

    typealias MergedSources = Set<MergedSource>

    private let directSelections: DirectSelections.ReadOnly?
    let typeInfo: SelectionSet.TypeInfo
    
    fileprivate(set) var mergedSources: MergedSources = []
    fileprivate(set) var fields: OrderedDictionary<String, Field> = [:]
    fileprivate(set) var conditionalSelectionSets: OrderedDictionary<ScopeCondition, SelectionSet> = [:]
    fileprivate(set) var fragments: OrderedDictionary<String, FragmentSpread> = [:]

    init(
      directSelections: DirectSelections.ReadOnly?,
      typeInfo: SelectionSet.TypeInfo
    ) {
      self.directSelections = directSelections
      self.typeInfo = typeInfo
    }

    func mergeIn(_ selections: EntityTreeScopeSelections, from source: MergedSource) {
      @IsEverTrue var didMergeAnySelections: Bool

      selections.fields.values.forEach { didMergeAnySelections = self.mergeIn($0) }
      selections.fragments.values.forEach { didMergeAnySelections = self.mergeIn($0) }

      if didMergeAnySelections {
        mergedSources.insert(source)
      }
    }

    private func mergeIn(_ field: IR.Field) -> Bool {
      let keyInScope = field.hashForSelectionSetScope
      if let directSelections = directSelections,
          directSelections.fields.keys.contains(keyInScope) {
        return false
      }

      let fieldToMerge: IR.Field
      if let entityField = field as? IR.EntityField {
        fieldToMerge = createShallowlyMergedNestedEntityField(from: entityField)

      } else {
        fieldToMerge = field
      }

      fields[keyInScope] = fieldToMerge
      return true
    }

    private func createShallowlyMergedNestedEntityField(from field: IR.EntityField) -> IR.EntityField {
      let newSelectionSet = IR.SelectionSet(
        entity: field.entity,
        parentType: field.selectionSet.typeInfo.parentType,
        typePath: self.typeInfo.typePath.appending(field.selectionSet.typeInfo.typeScope),
        mergedSelectionsOnly: true
      )
      return IR.EntityField(
        field.underlyingField,        
        selectionSet: newSelectionSet
      )
    }

    private func mergeIn(_ fragment: IR.FragmentSpread) -> Bool {
      let keyInScope = fragment.hashForSelectionSetScope
      if let directSelections = directSelections,
          directSelections.fragments.keys.contains(keyInScope) {
        return false
      }

      fragments[keyInScope] = fragment

      return true
    }

    func addMergedConditionalSelectionSet(with condition: ScopeCondition) {
      guard !typeInfo.isTypeCase else {
        return
      }

      if let directSelections = directSelections,
         directSelections.conditionalSelectionSets.keys.contains(condition) {
        return
      }

      conditionalSelectionSets[condition] = createShallowlyMergedConditionalSelectionSet(
        with: condition
      )
    }

    private func createShallowlyMergedConditionalSelectionSet(
      with condition: ScopeCondition
    ) -> SelectionSet {
      let parentType = condition.type ?? self.typeInfo.parentType
      return IR.SelectionSet(
        entity: self.typeInfo.entity,
        parentType: parentType,
        typePath: self.typeInfo.typePath.mutatingLast { $0.appending(parentType) },
        mergedSelectionsOnly: true
      )
      #warning("TODO: Type Path needs to append the whole ScopeCondition not just parentType.")
    }

    var isEmpty: Bool {
      fields.isEmpty && conditionalSelectionSets.isEmpty && fragments.isEmpty
    }

    static func == (lhs: MergedSelections, rhs: MergedSelections) -> Bool {
      lhs.mergedSources == rhs.mergedSources &&
      lhs.fields == rhs.fields &&
      lhs.conditionalSelectionSets == rhs.conditionalSelectionSets &&
      lhs.fragments == rhs.fragments
    }

    var debugDescription: String {
      """
      Merged Sources: \(mergedSources)
      Fields: \(fields.values.elements)
      TypeCases: \(conditionalSelectionSets.values.elements.map(\.typeInfo.parentType))
      Fragments: \(fragments.values.elements.map(\.definition.name))
      """
    }

  }

}
