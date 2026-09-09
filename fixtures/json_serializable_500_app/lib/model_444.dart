import 'package:json_annotation/json_annotation.dart';

part 'model_444.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model444 {
  const Model444({required this.id, required this.value});

  final int id;
  final String value;

  factory Model444.fromJson(Map<String, dynamic> json) =>
      _$Model444FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model444ToJson(this);
}
