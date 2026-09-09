import 'package:json_annotation/json_annotation.dart';

part 'model_386.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model386 {
  const Model386({required this.id, required this.value});

  final int id;
  final String value;

  factory Model386.fromJson(Map<String, dynamic> json) =>
      _$Model386FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model386ToJson(this);
}
