import 'package:json_annotation/json_annotation.dart';

part 'model_316.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model316 {
  const Model316({required this.id, required this.value});

  final int id;
  final String value;

  factory Model316.fromJson(Map<String, dynamic> json) =>
      _$Model316FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model316ToJson(this);
}
