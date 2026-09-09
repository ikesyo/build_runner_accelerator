import 'package:json_annotation/json_annotation.dart';

part 'model_081.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model081 {
  const Model081({required this.id, required this.value});

  final int id;
  final String value;

  factory Model081.fromJson(Map<String, dynamic> json) =>
      _$Model081FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model081ToJson(this);
}
