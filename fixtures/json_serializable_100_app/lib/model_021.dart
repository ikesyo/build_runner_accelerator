import 'package:json_annotation/json_annotation.dart';

part 'model_021.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model021 {
  const Model021({required this.id, required this.value});

  final int id;
  final String value;

  factory Model021.fromJson(Map<String, dynamic> json) =>
      _$Model021FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model021ToJson(this);
}
