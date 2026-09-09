import 'package:json_annotation/json_annotation.dart';

part 'model_111.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model111 {
  const Model111({required this.id, required this.value});

  final int id;
  final String value;

  factory Model111.fromJson(Map<String, dynamic> json) =>
      _$Model111FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model111ToJson(this);
}
