import 'package:json_annotation/json_annotation.dart';

part 'model_099.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model099 {
  const Model099({required this.id, required this.value});

  final int id;
  final String value;

  factory Model099.fromJson(Map<String, dynamic> json) =>
      _$Model099FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model099ToJson(this);
}
