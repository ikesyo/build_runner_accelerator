import 'package:json_annotation/json_annotation.dart';

part 'model_442.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model442 {
  const Model442({required this.id, required this.value});

  final int id;
  final String value;

  factory Model442.fromJson(Map<String, dynamic> json) =>
      _$Model442FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model442ToJson(this);
}
