import 'package:json_annotation/json_annotation.dart';

part 'model_375.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model375 {
  const Model375({required this.id, required this.value});

  final int id;
  final String value;

  factory Model375.fromJson(Map<String, dynamic> json) =>
      _$Model375FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model375ToJson(this);
}
