import 'package:json_annotation/json_annotation.dart';

part 'model_110.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model110 {
  const Model110({required this.id, required this.value});

  final int id;
  final String value;

  factory Model110.fromJson(Map<String, dynamic> json) =>
      _$Model110FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model110ToJson(this);
}
